#!/usr/bin/env python3
import kopano
import subprocess
import os
import re
from collections import defaultdict

def run(cmd):
    out = subprocess.check_output(cmd, shell=True, text=True)
    return out.splitlines()

def detect_columns(header_line):
    """
    Ermittelt anhand der Kopfzeile die Spaltenindizes.
    Erwartet z.B.: 'User            Fullname        Homeserver'
    """
    cols = re.split(r'\s{2,}|\t+', header_line.strip())
    index_map = {name.lower(): i for i, name in enumerate(cols)}
    # Fallbacks für verschiedene Lokalisierungen
    user_idx = None
    for key in ("user", "username", "name", "benutzername"):
        if key in index_map:
            user_idx = index_map[key]
            break
    return user_idx

def parse_usernames(lines):
    """
    Parst die Ausgabe von `kopano-admin -l` und liefert die *Benutzernamen*.
    Nutzt die Kopfzeile zur Spaltenerkennung (nimmt NICHT den Fullname).
    """
    users = []
    header_seen = False
    user_idx = None

    for line in lines:
        s = line.strip()
        if not s:
            continue

        # Trennerzeilen überspringen
        if set(s) in ({'-'}, {'='}):
            continue

        # Kopfzeile erkennen
        if not header_seen and re.search(r'\bUser\b', s, flags=re.I):
            user_idx = detect_columns(s)
            header_seen = True
            continue

        # Wenn keine Kopfzeile erkannt wurde, versuche heuristisch zu splitten
        cols = re.split(r'\s{2,}|\t+', s)
        if not cols:
            continue

        if user_idx is not None and len(cols) > user_idx:
            uname = cols[user_idx].strip()
        else:
            # Heuristik: bei fehlender Kopfzeile nimm die erste Spalte als Username
            uname = cols[0].strip()

        # offensichtliche Nicht-User raus
        if uname in ("User", "Benutzername", "SYSTEM", "Everyone", ""):
            continue

        users.append(uname)

    # Deduplizieren & sortieren, optional
    return sorted(set(users))

def sanitize_name(name, fallback='contact'):
    s = (name or fallback).strip()
    s = re.sub(r'[\\/:*?"<>|]', '_', s)
    s = re.sub(r'\s+', ' ', s)
    if not s:
        s = fallback
    return s

def unique_path(base_dir, filename, ext=".vcf", counter_map=None):
    stem = sanitize_name(filename)
    if counter_map is None:
        counter_map = defaultdict(int)
    path = os.path.join(base_dir, f"{stem}{ext}")
    while os.path.exists(path):
        counter_map[stem] += 1
        path = os.path.join(base_dir, f"{stem}_{counter_map[stem]}{ext}")
    return path

def iter_contacts(user):
    """
    Liefert einen Iterator über Kontakte, egal ob `contacts` ein Attribut, callable
    oder None ist. Gibt bei Problemen einfach eine leere Liste zurück.
    """
    try:
        obj = getattr(user, "contacts", None)
        # falls es eine Methode ist
        if callable(obj):
            obj = obj()
        if obj is None:
            return []
        # prüfen, ob iterierbar
        try:
            iter(obj)
            return obj
        except TypeError:
            return []
    except Exception:
        return []

def main():
    # 1) Benutzerliste holen
    lines = run("kopano-admin -l")
    usernames = parse_usernames(lines)
    if not usernames:
        print("Keine Benutzer gefunden. Prüfe die Ausgabe von `kopano-admin -l`.")
        return

    # 2) Kopano-Server verbinden (ggf. Parameter wie host/user/pass setzen)
    server = kopano.Server()

    # 3) Export
    for uname in usernames:
        try:
            user = server.user(uname)
            if not user:
                print(f"[WARN] Benutzer '{uname}' konnte nicht geladen werden (None). Überspringe.")
                continue
        except Exception as e:
            print(f"[WARN] Benutzer '{uname}' konnte nicht geladen werden: {e}")
            continue

        export_dir = sanitize_name(uname)
        os.makedirs(export_dir, exist_ok=True)
        print(f"Exportiere Kontakte für '{uname}' -> Ordner: {export_dir}")

        dup_map = defaultdict(int)
        count = 0

        for contact in iter_contacts(user):
            # sinnvollen Dateinamen wählen
            raw_name = (
                getattr(contact, "name", None)
                or getattr(contact, "display_name", None)
                or getattr(contact, "email", None)
                or f"contact_{count+1}"
            )
            out_path = unique_path(export_dir, raw_name, ext=".vcf", counter_map=dup_map)

            try:
                vcard_bytes = contact.vcf()  # erwartet bytes
                with open(out_path, "wb") as f:
                    f.write(vcard_bytes)
                count += 1
            except Exception as e:
                print(f"[WARN] Kontakt '{raw_name}' bei Benutzer '{uname}' konnte nicht exportiert werden: {e}")

        print(f"Fertig: {count} Kontakt(e) für '{uname}' exportiert.\n")

if __name__ == "__main__":
    main()
