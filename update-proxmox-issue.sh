#!/usr/bin/env bash
# Proxmox VE Login Banner - revision 2026-10-25-r3
# NICs: two columns; load: 80/90 percent of cores; VMs: 3, LXCs: 2 columns
# Default: dark mode, /etc/motd ONLY (no pre-login disclosure)
# Themes: --norton (blue), --paradroid (light gray), --mono (ASCII)
# Other options: --issue --no-issue --no-motd
set -euo pipefail
if (( EUID != 0 )); then
    printf 'Bitte als root ausfuehren.\n' >&2
    exit 1
fi
exec python3 - "$@" <<'PY'
import argparse
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from datetime import datetime

# Einheitliche APT-/CLI-Ausgaben auch bei deutscher System-Locale.
os.environ['LC_ALL'] = 'C'

parser = argparse.ArgumentParser(description='Proxmox VE Login Banner mit Farbschemata')
theme_group = parser.add_mutually_exclusive_group()
theme_group.add_argument('--mono', action='store_true',
                         help='ASCII ohne Farbe (keine ANSI-Sequenzen)')
theme_group.add_argument('--norton', action='store_true',
                         help='Norton-Commander-Farben: blauer Hintergrund')
theme_group.add_argument('--paradroid', action='store_true',
                         help='Paradroid-Farben: hellgrauer Hintergrund')
issue_group = parser.add_mutually_exclusive_group()
issue_group.add_argument('--issue', action='store_true',
                         help='/etc/issue ausdruecklich zusaetzlich beschreiben')
issue_group.add_argument('--no-issue', action='store_true',
                         help='Kompatibilitaetsparameter: /etc/issue auslassen (Standard)')
parser.add_argument('--no-motd', action='store_true', help='/etc/motd nicht aktualisieren')
args = parser.parse_args()
TARGETS = ([] if args.no_motd else ['/etc/motd']) + (['/etc/issue'] if args.issue else [])
if not TARGETS:
    parser.error('Kein Ausgabeziel aktiv: fuer /etc/issue --issue angeben')
WIDTH = 76
# No traffic-light glyphs: the full inner width is usable.
TEXT_WIDTH = WIDTH
RESET = '\033[0m'
# Jede Farbdefinition enthaelt sowohl Vorder- als auch Hintergrundfarbe.
# So bleiben auch nach Zeilenumbruechen und in SSH-Terminals die Flaechen
# durchgaengig einheitlich. '--mono' ignoriert diese ANSI-Farbpaletten.
COLOR_SCHEMES = {
    'dark': {
        'normal': '\033[0;38;5;252;48;5;235m',
        'white':  '\033[1;38;5;255;48;5;235m',
        'yellow': '\033[1;38;5;180;48;5;235m',
        'cyan':   '\033[1;38;5;117;48;5;235m',
        'green':  '\033[1;38;5;114;48;5;235m',
        'red':    '\033[1;38;5;203;48;5;235m',
        'orange': '\033[1;38;5;215;48;5;235m',
    },
    'norton': {
        'normal': '\033[44;97m',
        'white':  '\033[1;44;97m',
        'yellow': '\033[1;44;93m',
        'cyan':   '\033[1;44;96m',
        'green':  '\033[1;44;92m',
        'red':    '\033[1;44;91m',
        'orange': '\033[1;38;5;208;44m',
    },
    'paradroid': {
        'normal': '\033[0;38;5;235;48;5;252m',
        'white':  '\033[1;38;5;232;48;5;252m',
        'yellow': '\033[1;38;5;238;48;5;252m',
        'cyan':   '\033[1;38;5;25;48;5;252m',
        'green':  '\033[1;38;5;28;48;5;252m',
        'red':    '\033[1;38;5;160;48;5;252m',
        'orange': '\033[1;38;5;130;48;5;252m',
    },
}
THEME = 'norton' if args.norton else 'paradroid' if args.paradroid else 'dark'
COLORS = COLOR_SCHEMES[THEME]

def run(command, timeout=8):
    if not shutil.which(command[0]):
        return 127, ''
    try:
        p = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, errors='replace', timeout=timeout, check=False)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 124, ''

def read_json(command, timeout=12):
    # SMART kann bei Fehlerindikatoren einen Nonzero-Returncode liefern,
    # aber trotzdem gueltige JSON-Daten zur Diagnose ausgeben.
    _, output = run(command, timeout)
    try:
        return json.loads(output)
    except (ValueError, TypeError):
        return {}

def number(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if isinstance(value, str):
        m = re.search(r'\d+(?:\.\d+)?', value.replace(',', ''))
        if m:
            return float(m.group())
    return None

def clean(value):
    return re.sub(r'[\x00-\x1f\x7f-\x9f]', '?', str(value))

def pad(value, width):
    value = clean(value)
    return (value[:width - 1] + '~' if len(value) > width else value.ljust(width))

def seg(text, color='normal'):
    return clean(text), color

def color_status(text):
    t = text.upper()
    if t in ('OK', 'ONLINE', 'HEALTH_OK', 'ACTIVE', 'UP'):
        return 'green'
    if t in ('UNKNOWN', 'WARN', 'WARNING', 'HEALTH_WARN'):
        return 'orange'
    return 'red'

# Utilization thresholds, applied uniformly to USED capacity, load and wear.
def utilization_color(used_pct):
    if used_pct is None:
        return 'orange'
    return 'red' if used_pct >= 80 else 'orange' if used_pct >= 75 else 'green'

def worst_color(*colors):
    severity = {'normal': 0, 'white': 0, 'cyan': 0, 'green': 0,
                'yellow': 1, 'orange': 1, 'red': 2}
    result = max(('green', *colors), key=lambda c: severity.get(c, 0))
    return 'orange' if result == 'yellow' else result

# SYSTEM / KERNEL
_, host = run(['hostname', '-f'])
if not host:
    _, host = run(['hostname'])
_, pve = run(['pveversion'])
version = pve.split('/', 1)[1].split('/', 1)[0] if '/' in pve else '?'
_, kernel = run(['uname', '-r'])
_, uptime = run(['uptime', '-p'])
uptime = uptime.removeprefix('up ') or '-'
now = datetime.now().strftime('%d.%m.%Y %H:%M')
_, installed_raw = run(['find', '/lib/modules', '-mindepth', '1', '-maxdepth', '1',
                        '-type', 'd', '-name', '*-pve', '-printf', '%f\n'])
installed = [x for x in installed_raw.splitlines() if x]
latest = ''
if installed:
    try:
        p = subprocess.run(['sort', '-V'], input='\n'.join(installed) + '\n',
                           text=True, capture_output=True, timeout=3, check=False)
        latest = p.stdout.splitlines()[-1] if p.stdout.splitlines() else ''
    except (OSError, subprocess.TimeoutExpired):
        pass
kernel_status = 'UNKNOWN' if not latest else 'OK' if kernel == latest else f'REBOOT? -> {latest}'

# Paketlisten werden nur aus dem vorhandenen APT-Cache gelesen;
# es wird weder apt update ausgefuehrt noch etwas installiert.
def pending_apt_updates():
    if not shutil.which('apt'):
        return None
    rc, output = run(['apt', 'list', '--upgradable'], timeout=20)
    if rc != 0:
        return None
    return sum(
        1 for line in output.splitlines()
        if re.search(r'\[upgradable from:', line, re.IGNORECASE)
    )

apt_updates = pending_apt_updates()
apt_text = f'{apt_updates} Updates' if apt_updates is not None else 'n/a'
apt_color = ('green' if apt_updates == 0 else
             'orange' if apt_updates is not None else 'orange')

# Letzten lokalen vzdump-Task aus der Proxmox-API lesen.
# Status=stopped allein bedeutet NICHT erfolgreich: exitstatus pruefen.
def last_vzdump():
    _, node = run(['hostname', '-s'])
    if not node:
        node = host.split('.')[0]
    path = f'/nodes/{node}/tasks'
    tasks = None
    for filter_args in (
        ['--typefilter', 'vzdump'],
        ['--type', 'vzdump'],
        [],
    ):
        args = ['pvesh', 'get', path] + filter_args + [
            '--limit', '500', '--output-format', 'json'
        ]
        response = read_json(args, timeout=15)
        if isinstance(response, list):
            tasks = [item for item in response
                     if isinstance(item, dict) and item.get('type') == 'vzdump']
            break

    if tasks is None:
        return 'Taskhistorie nicht erreichbar', 'orange'
    if not tasks:
        return 'kein lokaler vzdump-Lauf gefunden', 'orange'

    task = max(tasks, key=lambda x: int(x.get('starttime') or 0))
    upid = task.get('upid')
    if upid:
        detail = read_json([
            'pvesh', 'get', f'{path}/{upid}/status',
            '--output-format', 'json'
        ], timeout=10)
        if isinstance(detail, dict) and detail:
            task = dict(task, **detail)

    timestamp = task.get('endtime') or task.get('starttime')
    try:
        when = datetime.fromtimestamp(int(timestamp)).strftime('%d.%m. %H:%M')
    except (TypeError, ValueError, OSError, OverflowError):
        when = '?'

    status = str(task.get('status') or '').strip()
    exitstatus = task.get('exitstatus')
    if status.lower() in ('running', 'active'):
        return f'{when} RUNNING', 'orange'
    if status.lower() in ('stopped', 'ok', 'error', 'failed'):
        effective = str(exitstatus or status)
        if effective.upper() == 'OK':
            return f'{when} OK', 'green'
        if effective.lower() == 'stopped':
            return f'{when} Ergebnis unbekannt', 'orange'
        # Lange Fehlertexte passen nicht in den 80-Spalten-Rahmen.
        return f'{when} FEHLER: {effective[:55]}', 'red'
    if str(exitstatus).upper() == 'OK':
        return f'{when} OK', 'green'
    if exitstatus:
        return f'{when} FEHLER: {str(exitstatus)[:55]}', 'red'
    return f'{when} Status unbekannt', 'orange'

vzdump_text, vzdump_color = last_vzdump()

# RAM: MemAvailable includes reclaimable cache
mem = {}
try:
    with open('/proc/meminfo', encoding='ascii') as file:
        for line in file:
            name, _, value = line.partition(':')
            amount = number(value)
            if amount is not None:
                mem[name] = amount
except OSError:
    pass
mtotal = mem.get('MemTotal', 0)
mfree = mem.get('MemAvailable', mem.get('MemFree', 0))
used_kib = max(0, mtotal - mfree)
used_pct = used_kib * 100 / mtotal if mtotal else None
# Die Schreibweise ist kompakt genug fuer RAM, Cores und Load in EINER Zeile.
mem_text = (f'{used_kib/1048576:.1f}/{mtotal/1048576:.1f}GiB '
            f'USED {used_pct:.0f}%') if used_pct is not None else 'UNKNOWN'
mem_color = utilization_color(used_pct)

# Load Average fuer 1, 5, 15 Minuten, nicht mit CPU-Nutzung verwechseln.
cores = os.cpu_count() or 1
def load_status_color(value, logical_cores):
    """Green below 80%, orange through 90%, red above 90% of CPU cores."""
    if value is None:
        return 'orange'
    percentage = 100.0 * value / max(1, logical_cores)
    if percentage > 90:
        return 'red'
    if percentage >= 80:
        return 'orange'
    return 'green'


try:
    load_averages = os.getloadavg()
except OSError:
    load_averages = (None, None, None)

# IP-Adressen der Host-Netze sowie der virtuellen Interfaces.
# Keine separate VPN-/TUN-/TAP-Erkennung: ein TAP kann zu einer VM gehoeren.
VIRTUAL_PREFIXES = ('docker', 'br-', 'wg', 'tailscale', 'tun', 'tap', 'veth',
                    'virbr', 'zt', 'vxlan', 'flannel', 'cni', 'podman',
                    'kube', 'dummy', 'gre', 'gretap', 'ip6gre', 'ipip')


def physical_underlay(name, visited=None):
    if visited is None:
        visited = set()
    if name in visited:
        return False
    visited.add(name)
    base = f'/sys/class/net/{name}'
    if os.path.exists(f'{base}/device'):
        return True
    try:
        children = os.listdir(f'{base}/brif') if os.path.isdir(f'{base}/brif') else []
        children += [x[6:] for x in os.listdir(base) if x.startswith('lower_')]
    except OSError:
        children = []
    return any(physical_underlay(child, visited) for child in children)


def is_physical_ip(name):
    lower = name.lower()
    if lower.startswith(VIRTUAL_PREFIXES):
        return False
    return physical_underlay(name) or lower.startswith(('vmbr', 'bond'))


physical_ips, virtual_ips = [], []
ip_data = read_json(['ip', '-j', 'addr', 'show'])
if not isinstance(ip_data, list):
    ip_data = []

for iface in ip_data:
    name = iface.get('ifname', '')
    if not name or name == 'lo':
        continue
    for addr in iface.get('addr_info', []):
        if addr.get('family') not in ('inet', 'inet6') or addr.get('scope') != 'global':
            continue
        ip = addr.get('local')
        if ip:
            entry = f"{ip}/{addr.get('prefixlen', '?')}({name})"
            if is_physical_ip(name):
                physical_ips.append(entry)
            else:
                virtual_ips.append(entry)

physical_ips = list(dict.fromkeys(physical_ips))
virtual_ips = list(dict.fromkeys(virtual_ips))


# Physical NICs: nur administrativ aktive Schnittstellen (IFF_UP).
# Die maximal unterstuetzte Link-Geschwindigkeit ermitteln wir aus den
# ethtool-Supported-Link-Modes, nicht aus dem ausgehandelten aktuellen Wert.
def nic_link_speeds(ethtool_output):
    """Gibt die maximale in ethtool beworbene Full-Duplex-Geschwindigkeit zurueck."""
    supported = []
    in_modes = False
    for line in ethtool_output.splitlines():
        if re.match(r'^\s*Supported link modes\s*:', line, re.I):
            in_modes = True
            line = line.split(':', 1)[1]
        elif in_modes and re.match(r'^\s+[A-Za-z][A-Za-z -]*:', line):
            break
        elif not in_modes:
            continue
        for rate, duplex_mode in re.findall(r'(\d+)base[\w/.-]*?/(Full|Half)', line, re.I):
            if duplex_mode.lower() == 'full':
                supported.append(int(rate))
    return max(supported) if supported else None


def nic_speed_text(mbps):
    if mbps is None:
        return '?'
    return f'{mbps/1000:g}G' if mbps >= 1000 else f'{mbps}M'


nics = []
try:
    interfaces = sorted(os.listdir('/sys/class/net'))
except OSError:
    interfaces = []

for name in interfaces:
    base = f'/sys/class/net/{name}'
    if not os.path.exists(f'{base}/device'):
        continue
    try:
        with open(f'{base}/flags', encoding='ascii') as flags_file:
            administratively_up = bool(int(flags_file.read().strip(), 16) & 0x1)
    except (OSError, ValueError):
        administratively_up = False
    if not administratively_up:
        continue

    carrier, speed_mbps, duplex = None, None, '?'
    for key in ('carrier', 'speed', 'duplex'):
        try:
            with open(f'{base}/{key}') as f:
                value = f.read().strip()
            if key == 'carrier':
                carrier = value
            elif key == 'speed':
                mb = int(value)
                if 0 < mb < 1000000:
                    speed_mbps = mb
            else:
                duplex = value.upper()
        except (OSError, ValueError):
            pass

    # ethtool liefert sowohl den ausgehandelten Speed als auch die unterstuetzten
    # Link-Modi. Fehlen die Angaben, nicht grundlos eine Warnung ausloesen.
    _, eth = run(['ethtool', name], timeout=3)
    if carrier is None:
        if 'Link detected: yes' in eth:
            carrier = '1'
        elif 'Link detected: no' in eth:
            carrier = '0'
    if speed_mbps is None:
        m = re.search(r'^\s*Speed:\s*(\d+)Mb/s', eth, re.M)
        if m:
            speed_mbps = int(m.group(1))
    if duplex == '?':
        m = re.search(r'^\s*Duplex:\s*(\w+)', eth, re.M)
        if m:
            duplex = m.group(1).upper()

    max_speed_mbps = nic_link_speeds(eth)
    reduced_speed = (
        carrier == '1' and (
            (speed_mbps is not None and max_speed_mbps is not None
             and speed_mbps < max_speed_mbps)
            or duplex == 'HALF'
        )
    )
    if carrier == '0':
        status, status_color = 'DOWN', 'red'
        link, link_color = '-', 'red'
    elif carrier == '1':
        status = 'UP'
        status_color = 'orange' if reduced_speed else 'green'
        link = f'{nic_speed_text(speed_mbps)}/{duplex}'
        link_color = 'orange' if reduced_speed else 'normal'
    else:
        status, status_color = 'UNKNOWN', 'orange'
        link, link_color = f'{nic_speed_text(speed_mbps)}/{duplex}', 'normal'
    nics.append((name, status, status_color, link, link_color))

# Guest IDs white, guest names colored by status. LXC hostname can be an FQDN
# in /etc/pve/lxc/<CTID>.conf; if only a short hostname is configured, use
# its explicit searchdomain where available (do not assume the node's domain).
def lxc_hostname_fqdn(ctid, fallback):
    hostname = fallback
    domain = ''
    filename = f'/etc/pve/lxc/{ctid}.conf'
    try:
        with open(filename, encoding='utf-8', errors='replace') as config:
            for line in config:
                if line.startswith('hostname:'):
                    hostname = line.partition(':')[2].strip() or hostname
                elif line.startswith('searchdomain:'):
                    domain = line.partition(':')[2].strip().split()[0]
    except OSError:
        return hostname
    if hostname and '.' not in hostname and domain:
        hostname += '.' + domain.lstrip('.')
    return hostname


def get_guests(command, container=False):
    rc, output = run(command, timeout=10)
    if rc != 0:
        return []
    result = []
    for line in output.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 3 or not fields[0].isdigit():
            continue
        name = fields[-1] if container else fields[1]
        if container:
            name = lxc_hostname_fqdn(fields[0], name)
        status = (fields[1] if container else fields[2]).lower()
        color = 'green' if status == 'running' else 'orange' if status == 'stopped' else 'red'
        result.append((fields[0], name, color))
    return result
vms = get_guests(['qm', 'list'])
lxcs = get_guests(['pct', 'list'], container=True)

# Datastores: show USED percentage (not free percentage).
# pvesm status columns: Name Type Status Total Used Available %
storages = []
rc, storage_output = run(['pvesm', 'status'], timeout=12)
if rc == 0:
    for line in storage_output.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 3:
            continue
        # Inaktive / deaktivierte Storages vollstaendig ausblenden.
        if fields[2].lower() != 'active' or len(fields) < 7:
            continue
        total_kib = number(fields[3])
        used_kib = number(fields[4])
        available_kib = number(fields[5])
        used_pct = number(fields[6])
        if used_pct is None and total_kib:
            if used_kib is not None:
                used_pct = 100.0 * used_kib / total_kib
            elif available_kib is not None:
                used_pct = 100.0 * (total_kib - available_kib) / total_kib
        # pvesm already reports the used percentage; keep its value.
        used_text = f'{used_pct:.0f}%' if used_pct is not None else '?'
        color = utilization_color(used_pct)
        storages.append((fields[0], used_text, color))

# ZFS: over 80% used is red; active scrub/resilver/trim also red.
zpools, zfs_jobs, zfs_warnings = [], [], []
if shutil.which('zpool'):
    _, output = run(['zpool', 'list', '-H', '-o', 'name,health,capacity'], timeout=10)
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        name, health, used = fields[:3]
        usage = number(used)
        color = 'red' if health != 'ONLINE' else utilization_color(usage)
        zpools.append((name, health, used, color))
        rc, detail = run(['zpool', 'status', name], timeout=10)
        if rc != 0:
            zfs_warnings.append(f'{name}: Status nicht abrufbar')
            continue
        for detail_line in detail.splitlines():
            lower = detail_line.strip().lower()
            if lower.startswith('scan:') and ('scrub in progress' in lower or 'resilver in progress' in lower):
                zfs_jobs.append(f"{name}: {'RESILVER' if 'resilver' in lower else 'SCRUB'} RUNNING")
            if lower.startswith('trim:') and ('in progress' in lower or 'trimming' in lower):
                zfs_jobs.append(f'{name}: TRIM RUNNING')
        if health != 'ONLINE':
            zfs_warnings.append(f'{name}: {health}')

# Proxmox cluster
cluster = 'Standalone'
if os.path.exists('/etc/pve/corosync.conf') or os.path.exists('/etc/corosync/corosync.conf'):
    rc, info = run(['pvecm', 'status'], timeout=8)
    if rc != 0:
        cluster = 'ERROR: Cluster nicht erreichbar'
    else:
        values = dict((a.strip(), b.strip()) for a, b in re.findall(r'^([^:\n]+):\s*(.+)$', info, re.M))
        quorum = 'OK' if values.get('Quorate', '').lower() == 'yes' else 'ERROR'
        cluster = (f"{values.get('Name','?')} | Nodes: {values.get('Nodes','?')} | "
                   f"Votes: {values.get('Total votes','?')}/{values.get('Expected votes','?')} | Quorum: {quorum}")

# Ceph - Statusdaten verschiedener Releases koennen unterschiedlich verschachtelt sein.
# Fallback ueber ceph osd stat, dann ceph osd dump (gleiche Ceph-CLI-Credentials).
def osd_counts(data):
    if not isinstance(data, dict):
        return None
    queue = [data]
    while queue:
        obj = queue.pop(0)
        if not isinstance(obj, dict):
            continue
        if all(key in obj for key in ('num_osds', 'num_up_osds', 'num_in_osds')):
            try:
                return tuple(int(obj[k]) for k in
                             ('num_osds', 'num_up_osds', 'num_in_osds'))
            except (TypeError, ValueError):
                pass
        for key in ('osdmap', 'osd_stat', 'osdmap_summary', 'osdmap_info'):
            value = obj.get(key)
            if isinstance(value, dict):
                queue.append(value)
    return None

def osd_counts_from_dump(data):
    result = osd_counts(data)
    if result is not None:
        return result
    osds = data.get('osds') if isinstance(data, dict) else None
    if not isinstance(osds, list):
        return None
    try:
        return (len(osds),
                sum(int(o.get('up', 0)) for o in osds),
                sum(int(o.get('in', 0)) for o in osds))
    except (TypeError, ValueError, AttributeError):
        return None

ceph, ceph_details = 'nicht konfiguriert', ''
ceph_osd_missing = False
if os.path.exists('/etc/pve/ceph.conf') or os.path.exists('/etc/ceph/ceph.conf'):
    data = read_json(['ceph', 'status', '--format', 'json'], timeout=10)
    if not isinstance(data, dict) or not data:
        ceph = 'ERROR: Ceph nicht erreichbar'
    else:
        health_data = data.get('health') or {}
        health = health_data.get('status', 'UNKNOWN')
        counts = osd_counts(data)
        if counts is None:
            counts = osd_counts(read_json(
                ['ceph', 'osd', 'stat', '--format', 'json'], timeout=10
            ))
        if counts is None:
            counts = osd_counts_from_dump(read_json(
                ['ceph', 'osd', 'dump', '--format', 'json'], timeout=10
            ))

        if counts is None:
            ceph_osd_missing = True
            osd_display = 'OSD: ?/? | IN: ?'
        else:
            total, up, inside = counts
            osd_display = f'OSD: {up}/{total} | IN: {inside}'

        mons = data.get('quorum_names')
        if isinstance(mons, list):
            mon_count = len(mons)
        else:
            mon_count = len(data.get('quorum') or [])

        ceph = f'{health} | {osd_display} | MON: {mon_count}'
        if health != 'HEALTH_OK':
            ceph_details = ', '.join(list((health_data.get('checks') or {}).keys())[:3])
        if ceph_osd_missing:
            prefix = (ceph_details + ' | ') if ceph_details else ''
            ceph_details = prefix + 'OSD-Daten nicht abrufbar (JSON/Rechte pruefen)'

# Multipath
multipath, multipath_details = None, ''
if shutil.which('multipath') or shutil.which('multipathd'):
    rc, state = run(['systemctl', 'is-active', 'multipathd'], timeout=4)
    if rc != 0 or state != 'active':
        multipath = 'ERROR: multipathd nicht aktiv'
    else:
        rc, output = run(['multipathd', 'show', 'paths', 'raw', 'format', '%d %t %T %o'], timeout=8)
        if rc != 0:
            multipath = 'ERROR: Pfade nicht abrufbar'
        else:
            total, failed = 0, []
            for line in output.splitlines():
                fields = line.split()
                if len(fields) != 4 or fields[0].lower() in ('dev', 'device'):
                    continue
                device, dm, checker, online = fields
                total += 1
                if dm.lower() == 'failed' or checker.lower() in ('faulty', 'shaky') or online.lower() == 'offline':
                    failed.append(device)
            multipath = (f'ERROR: {len(failed)}/{total} Pfade defekt' if failed else f'OK ({total} Pfade)')
            multipath_details = ', '.join(failed)
            mrc, maps = run(['multipathd', 'show', 'maps', 'raw', 'format', '%n %t'], timeout=8)
            if mrc == 0:
                inactive = [parts[0] for ln in maps.splitlines() if len(parts := ln.split()) >= 2 and parts[1].lower() != 'active']
                if inactive:
                    multipath += f' | ERROR: {len(inactive)} Maps inaktiv'
                    multipath_details += ('; ' if multipath_details else '') + ', '.join(inactive)

# NUT
def nut_targets():
    targets = []
    files = ['/etc/nut/upsmon.conf'] + sorted(glob.glob('/etc/nut/upsmon.conf.d/*.conf'))
    for filename in files:
        try:
            with open(filename, encoding='utf-8', errors='replace') as file:
                for line in file:
                    try:
                        fields = shlex.split(line, comments=True)
                    except ValueError:
                        continue
                    if len(fields) >= 2 and fields[0].upper() == 'MONITOR':
                        targets.append(fields[1])
        except OSError:
            pass
    if not targets:
        rc, output = run(['upsc', '-l'], timeout=5)
        if rc == 0:
            targets = [f'{name.strip()}@localhost' for name in output.splitlines() if name.strip()]
    return list(dict.fromkeys(targets))

def read_ups(target):
    rc, output = run(['upsc', target], timeout=6)
    if rc != 0 or not output:
        return f'{target}: ERROR', 'red'
    fields = {}
    for line in output.splitlines():
        key, colon, value = line.partition(':')
        if colon:
            fields[key.strip()] = value.strip()
    raw = fields.get('ups.status', '')
    flags = set(raw.split())
    if flags.intersection({'FSD', 'LB', 'RB'}):
        state, color = f'WARN ({raw})', 'red'
    elif 'OB' in flags:
        state, color = f'BATTERIE ({raw})', 'red'
    elif 'OL' in flags:
        state, color = f'NETZ ({raw})', 'green'
    else:
        state, color = raw or 'UNKNOWN', 'yellow'
    parts = [f'{target}: {state}']
    if fields.get('battery.charge'):
        parts.append(f"Akku {fields['battery.charge']}%")
    runtime = number(fields.get('battery.runtime'))
    if runtime is not None:
        parts.append(f'Rest {runtime/60:.0f} min')
    if fields.get('ups.load'):
        parts.append(f"Last {fields['ups.load']}%")
    # For UPS values, battery charge is a remaining percentage, while
    # ups.load is a utilization percentage. Apply 75/80 consistently.
    battery_charge = number(fields.get('battery.charge'))
    ups_load = number(fields.get('ups.load'))
    if battery_charge is not None:
        color = worst_color(color, utilization_color(100 - battery_charge))
    if ups_load is not None:
        color = worst_color(color, utilization_color(ups_load))
    return ' | '.join(parts), color

if shutil.which('upsc'):
    targets = nut_targets()
    ups_lines = [read_ups(target) for target in targets[:10]] if targets else [('Keine USV gefunden', 'yellow')]
else:
    ups_lines = [('NUT nicht installiert', 'yellow')]

# Checkmk spool local-check summary.
# Checkmk interprets a leading integer in the filename as maximum age in
# seconds since last modification (mtime), NOT the filesystem birth time.
# Files past that deadline are ignored by the agent and deleted here.
# Only ordinary regular files are removed; dotfiles and symlinks are ignored.
def checkmk_local_summary(folder='/var/lib/check_mk_agent/spool'):
    import stat
    import time

    if not os.path.isdir(folder):
        return 0, 0, 0, 'Spool-Verzeichnis fehlt', 'yellow'

    total, good, file_errors, deletion_errors = 0, 0, 0, 0
    now = time.time()

    try:
        with os.scandir(folder) as entries:
            files = sorted(
                (entry.name for entry in entries
                 if not entry.name.startswith('.')
                 and entry.is_file(follow_symlinks=False))
            )
    except OSError:
        return 0, 0, 0, 'Spool-Verzeichnis nicht lesbar', 'red'

    for basename in files:
        filename = os.path.join(folder, basename)
        try:
            metadata = os.stat(filename, follow_symlinks=False)
            if not stat.S_ISREG(metadata.st_mode):
                continue

            # The Checkmk agent extracts the initial digits, e.g.:
            #   90000_backup          -> valid for 90000 seconds
            #   3900_hourly           -> valid for 3900 seconds
            #   backup                -> no expiration
            match = re.match(r'^(\d+)', basename)
            if match:
                max_age = int(match.group(1))
                if now - metadata.st_mtime > max_age:
                    # Avoid deleting files modified/replaced since the scan.
                    latest = os.stat(filename, follow_symlinks=False)
                    if not stat.S_ISREG(latest.st_mode):
                        continue
                    if (latest.st_ino != metadata.st_ino
                            or latest.st_dev != metadata.st_dev
                            or latest.st_mtime_ns != metadata.st_mtime_ns
                            or time.time() - latest.st_mtime <= max_age):
                        continue
                    try:
                        os.unlink(filename)
                    except OSError:
                        deletion_errors += 1
                    # Expired checks are never counted, even if deletion fails.
                    continue

            with open(filename, 'r', encoding='utf-8-sig',
                      errors='replace') as file:
                first = file.readline().strip()
                if not re.fullmatch(r'<<<local(?::[^>]*)?>>>', first):
                    continue
                in_local = True
                for raw in file:
                    # Bei der Statuspruefung gilt exakt der Zeilenanfang:
                    # Nur '0 ' in Spalte 1 ist OK; ' 0 ' ist NICHT OK.
                    line = raw.rstrip('\r\n')
                    stripped = line.strip()
                    if not stripped or stripped.startswith('#'):
                        continue
                    if stripped.startswith('<<<') and stripped.endswith('>>>'):
                        in_local = bool(re.fullmatch(
                            r'<<<local(?::[^>]*)?>>>', stripped
                        ))
                        continue
                    if not in_local:
                        continue
                    total += 1
                    if line.startswith('0 '):
                        good += 1

        except OSError:
            file_errors += 1

    failed = total - good
    if total == 0 and not (file_errors or deletion_errors):
        return total, good, failed, 'Keine lokalen Spool-Checks', 'yellow'

    result = f'{good}/{total} checks OK'
    if file_errors:
        result += f' | {file_errors} Datei(en) nicht lesbar'
    if deletion_errors:
        result += f' | {deletion_errors} veraltete Datei(en) nicht loeschbar'

    color = ('red' if failed >= 2 or file_errors or deletion_errors
             else 'orange' if failed == 1 else 'green')
    return total, good, failed, result, color

checkmk_total, checkmk_ok, checkmk_bad, checkmk_text, checkmk_color = checkmk_local_summary()

# SMART / wearout / lifetime estimation
# Lifetime estimate assumes the same wear-per-power-on-hour rate continues.
# It estimates remaining *write endurance*, NOT hardware failure time.
def smart_values(data):
    # HPE VK1920GFLKL / SK hynix SE3010:
    # Die smartmontools-Datenbank kennt diese SSD nicht und meldet
    # SMART 231 als Unknown_SSD_Attribute. Hier steht der normierte
    # Wert (VALUE) fuer die verbleibende Schreib-Lebensdauer.
    # Die Ausnahme ist absichtlich auf das verifizierte Modell begrenzt.
    model = str(data.get('model_name') or '').strip().upper()
    known_hpe_231_life_left = model == 'VK1920GFLKL'
    nvme = data.get('nvme_smart_health_information_log') or {}
    hours = number(nvme.get('power_on_hours'))
    wear = number(nvme.get('percentage_used'))
    if hours is None:
        hours = number((data.get('power_on_time') or {}).get('hours'))
    attrs = (data.get('ata_smart_attributes') or {}).get('table') or []
    if hours is None:
        for attr in attrs:
            if attr.get('id') == 9:
                hours = number((attr.get('raw') or {}).get('value'))
                break
    if wear is None:
        for aid in (233, 177, 231, 202):
            for attr in attrs:
                if attr.get('id') != aid:
                    continue
                name = str(attr.get('name', '')).lower()
                norm = number(attr.get('value'))
                raw = number((attr.get('raw') or {}).get('value'))
                if aid == 233 and any(t in name for t in ('wearout', 'life_left', 'lifetime_remain')):
                    if norm is not None and 0 <= norm <= 100:
                        wear = 100 - norm
                elif aid == 177 and 'wear_level' in name:
                    if norm is not None and 0 <= norm <= 100:
                        wear = 100 - norm
                elif aid == 231:
                    named_life_left = any(
                        t in name for t in ('life_left', 'lifetime_remain', 'ssd_life')
                    )
                    # Nur fuer diese HPE-SSD darf 'Unknown_SSD_Attribute'
                    # anhand des bekannten Modells als Life Left gelten.
                    hpe_unknown = (
                        known_hpe_231_life_left
                        and name == 'unknown_ssd_attribute'
                        and raw is not None and norm is not None
                        and int(raw) == int(norm)
                    )
                    if (named_life_left or hpe_unknown) and norm is not None and 0 <= norm <= 100:
                        wear = 100 - norm
                elif aid == 202 and 'lifetime' in name:
                    if 'used' in name and raw is not None and 0 <= raw <= 100:
                        wear = raw
                    elif 'remain' in name and norm is not None and 0 <= norm <= 100:
                        wear = 100 - norm
                if wear is not None:
                    break
            if wear is not None:
                break
    wear_text = f'{wear:.0f}%' if wear is not None else '-'
    years = f'{hours/8766:.1f}' if hours is not None else '-'
    # Avoid extrapolating zero wear and unknown lifetime or for spinning HDDs.
    if wear is None or hours is None or hours <= 0:
        remain = '-'
    elif wear >= 100:
        remain = '0.0'
    elif wear > 0:
        estimate = (hours / 8766.0) * (100.0 - wear) / wear
        remain = f'{estimate:.1f}' if estimate < 100 else '>99'
    else:
        remain = '-'
    return wear_text, years, remain, wear

def smart_health(data, wear):
    if not data:
        return 'UNKNOWN', 'yellow'
    passed = (data.get('smart_status') or {}).get('passed')
    if passed is False:
        return 'BAD', 'red'
    attrs = (data.get('ata_smart_attributes') or {}).get('table') or []
    for attr in attrs:
        if attr.get('id') in (5, 187, 197, 198):
            raw = number((attr.get('raw') or {}).get('value'))
            if raw is not None and raw > 0:
                return 'BAD', 'red'
        when_failed = attr.get('when_failed')
        if when_failed and str(when_failed).strip().lower() not in ('-', 'none'):
            return 'BAD', 'red'
    nvme = data.get('nvme_smart_health_information_log') or {}
    warning = nvme.get('critical_warning', 0)
    try:
        if (any(warning.values()) if isinstance(warning, dict) else int(warning) != 0):
            return 'BAD', 'red'
    except (TypeError, ValueError):
        pass
    if (number(nvme.get('media_errors')) or 0) > 0 or (wear is not None and wear >= 100):
        return 'BAD', 'red'
    if passed is True or attrs or nvme:
        return 'OK', 'green'
    return 'UNKNOWN', 'yellow'

# Physical block devices; virtual ZFS zvol / dm excluded.
disks = []
block = read_json(['lsblk', '-J', '-d', '-o', 'NAME,TYPE,MODEL,SERIAL'])
for disk in block.get('blockdevices', []):
    name = str(disk.get('name') or '')
    if disk.get('type') != 'disk' or name.startswith(('zd', 'loop', 'ram', 'nbd', 'rbd', 'dm-', 'zram')):
        continue
    smart = read_json(['smartctl', '-a', '-j', f'/dev/{name}'], timeout=15)
    model = str(disk.get('model') or smart.get('model_name') or 'unknown').strip()
    serial = str(disk.get('serial') or smart.get('serial_number') or '-').strip()
    wear_text, years, remain, wear = smart_values(smart)
    health, health_color = smart_health(smart, wear)
    wear_color = utilization_color(wear) if wear is not None else 'normal'
    disk_color = worst_color(health_color, wear_color)
    # Modellfarbe zeigt ausschliesslich den SMART-Zustand (OK/WARN/BAD).
    # Verschleiss wird separat am Wearout-Prozentwert eingefaerbt.
    disks.append((model, serial, wear_text, years, remain, health_color, wear_color))

# Render input as colored text segments.
ROWS = []
def row(*parts):
    segments = [part if isinstance(part, tuple) else seg(part) for part in parts]
    ROWS.append(('row', segments))
def section(title):
    ROWS.append(('section', clean(title)))
# VM IDs (3 columns) and CT IDs (2 columns) are right-aligned and white.
# Only guest names carry their running/stopped/error color. Names are clipped
# within each cell, never wrapped onto extra rows.
GUEST_COL_GAP = 2
GUEST_ID_WIDTH = 6


def guest_cell(guest, width):
    if guest is None:
        return [seg(' ' * width)]
    guest_id, guest_name, status_color = guest
    name_width = width - GUEST_ID_WIDTH
    guest_id = clean(guest_id)[-(GUEST_ID_WIDTH - 1):]
    guest_name = clean(guest_name)[:name_width]
    return [
        seg(f'{guest_id:>{GUEST_ID_WIDTH - 1}}:', 'white'),
        seg(f'{guest_name:<{name_width}}', status_color),
    ]


def guests_row(label, guests, columns):
    row(seg(f'{label}:', 'cyan'))
    if not guests:
        row(seg('  -', 'orange'))
        return
    col_width = (TEXT_WIDTH - (columns - 1) * GUEST_COL_GAP) // columns
    for offset in range(0, len(guests), columns):
        parts = []
        for col in range(columns):
            if col:
                parts.append(seg(' ' * GUEST_COL_GAP))
            guest = guests[offset + col] if offset + col < len(guests) else None
            parts.extend(guest_cell(guest, col_width))
        row(*parts)

row(seg(f'PROXMOX VE {version}', 'yellow'), seg(f' | {host}', 'white'))
row('Kernel  : ', seg(kernel, 'white'), ' [',
    seg(kernel_status, 'green' if kernel_status == 'OK' else 'orange'
        if kernel_status == 'UNKNOWN' or kernel_status.startswith('REBOOT?') else 'red'),
    ']  | APT: ', seg(apt_text, apt_color))
row(f'Uptime  : {uptime}')
row('Vzdump  : ', seg(vzdump_text, vzdump_color))
load_parts = []
for index, (minutes, value) in enumerate(zip((1, 5, 15), load_averages)):
    if index:
        load_parts.append(seg(' '))
    value_text = f'{value:.1f}'.replace('.', ',') if value is not None else '?'
    load_parts.extend((
        seg(f'{minutes}m:', 'white'),
        seg(value_text, load_status_color(value, cores)),
    ))
row('Memory  : ', seg(mem_text, mem_color),
    ' | ', seg(f'{cores} Kerne', 'white'), ' | Load ', *load_parts)

section('PHYSICAL NETWORK INTERFACES')
# Two evenly spaced columns. Interface names always start at the same column.
NIC_COL_GAP = 2
NIC_COL_WIDTH = (TEXT_WIDTH - NIC_COL_GAP) // 2
NIC_NAME_WIDTH = 15
NIC_STATUS_WIDTH = 7
NIC_SPEED_WIDTH = NIC_COL_WIDTH - NIC_NAME_WIDTH - NIC_STATUS_WIDTH - 3


def nic_cell(nic):
    if nic is None:
        return [seg(' ' * NIC_COL_WIDTH)]
    name, status, status_color, speed, speed_color = nic
    return [
        seg(f'{clean(name)[:NIC_NAME_WIDTH]:<{NIC_NAME_WIDTH}}', 'white'),
        seg(' '),
        seg(f'{status:<{NIC_STATUS_WIDTH}}', status_color),
        seg(' '),
        seg(f'{clean(speed)[:NIC_SPEED_WIDTH]:<{NIC_SPEED_WIDTH}}', speed_color),
        seg(' '),
    ]


if nics:
    row(seg('NICs:', 'cyan'))
    for offset in range(0, len(nics), 2):
        left_nic = nics[offset]
        right_nic = nics[offset + 1] if offset + 1 < len(nics) else None
        row(*(nic_cell(left_nic) + [seg(' ' * NIC_COL_GAP)] + nic_cell(right_nic)))
else:
    row('NICs    : -')
row('IP phys : ', seg(', '.join(physical_ips) or '-', 'cyan'))

section('VIRTUAL NETWORK INTERFACES')
row('IP virt : ', seg(', '.join(virtual_ips) or '-', 'cyan'))

section('VIRTUAL MACHINES / CONTAINERS')
guests_row('VMs', vms, columns=3)
guests_row('LXCs', lxcs, columns=2)
section('CLUSTER / CEPH / MULTIPATH')
row(
    'Cluster : ',
    seg(cluster, 'red' if 'ERROR' in cluster else 'green' if 'Quorum: OK' in cluster or cluster == 'Standalone' else 'orange'),
    '   Ceph : ',
    seg(ceph, 'orange' if ceph_osd_missing else 'green' if 'HEALTH_OK' in ceph or ceph == 'nicht konfiguriert' else 'orange' if 'HEALTH_WARN' in ceph else 'red' if 'ERROR' in ceph or 'HEALTH_ERR' in ceph else 'orange')
)
if ceph_details:
    row('Ceph    : ', seg(ceph_details, 'orange' if ceph_osd_missing else 'red'))
if multipath is not None:
    row('MPath   : ', seg(multipath, 'red' if 'ERROR' in multipath else 'green'))
    if multipath_details:
        row('MPath   : ', seg(multipath_details, 'red'))

section('UPS / NUT')
for text, color in ups_lines:
    row('UPS     : ', seg(text, color))

section('SPOOL CHECKS')
row('Spool Checks: ', seg(checkmk_text, checkmk_color))

# Datastores: zwei Spalten, nur aktive Datastores, voller Name und USED%.
# 2 x 38 Zeichen = 76 Zeichen Innenbreite. Sehr lange Namen werden
# innerhalb IHRER Spalte umgebrochen, niemals mit ~ abgekuerzt.
section('DATASTORES (USED%)')
STORAGE_COLUMN_GAP = 2
STORAGE_COLUMN_WIDTH = (TEXT_WIDTH - STORAGE_COLUMN_GAP) // 2
STORAGE_PERCENT_WIDTH = 5
STORAGE_NAME_WIDTH = STORAGE_COLUMN_WIDTH - STORAGE_PERCENT_WIDTH - 1


def datastore_cell(index):
    if index >= len(storages):
        return []

    name, used_pc, color = storages[index]
    # Belegungswarnungen faerben nur den Prozentwert, nicht den Namen.
    # Ein fehlender/ungueltiger Prozentwert gilt als Fehler: beide rot.
    name_color = 'red' if used_pc == '?' else 'white'
    if used_pc == '?':
        color = 'red'
    name = clean(name)
    chunks = [
        name[j:j + STORAGE_NAME_WIDTH]
        for j in range(0, len(name), STORAGE_NAME_WIDTH)
    ] or ['']

    # Der Prozentwert steht in der letzten Zeile der betreffenden Zelle.
    # Alle Teilzeilen haben exakt STORAGE_COLUMN_WIDTH Zeichen.
    result = []
    for j, chunk in enumerate(chunks):
        percentage = used_pc if j == len(chunks) - 1 else ''
        result.append([
            seg(f'{chunk:<{STORAGE_NAME_WIDTH}} ', name_color),
            seg(f'{percentage:>{STORAGE_PERCENT_WIDTH}}', color),
        ])
    return result


header = f'{"NAME":<{STORAGE_NAME_WIDTH}} {"USED%":>{STORAGE_PERCENT_WIDTH}}'
row(seg(header, 'cyan'), seg(' ' * STORAGE_COLUMN_GAP), seg(header, 'cyan'))

if not storages:
    row(seg('Keine Datastores ermittelt', 'orange'))
else:
    for i in range(0, len(storages), 2):
        left = datastore_cell(i)
        right = datastore_cell(i + 1)
        for j in range(max(len(left), len(right))):
            left_part = (left[j] if j < len(left)
                         else [seg(' ' * STORAGE_COLUMN_WIDTH)])
            right_part = (right[j] if j < len(right)
                          else [seg(' ' * STORAGE_COLUMN_WIDTH)])
            row(*(left_part + [seg(' ' * STORAGE_COLUMN_GAP)] + right_part))

# ZFS weiter kompakt als eigene Liste unter den Datastores.
section('ZFS POOLS (USED)')
row(seg(f"{'POOL':<24} {'STATE':<12} {'USED%':>6}", 'cyan'))
if not zpools:
    row('Keine ZFS-Pools ermittelt')
for name, health, used, color in zpools:
    has_error = health.upper() != 'ONLINE' or number(used) is None
    row(
        seg(f'{pad(name, 24)} ', 'red' if has_error else 'white'),
        seg(f'{health:<12} ', 'red' if has_error else 'green'),
        seg(f'{used:>6}', 'red' if has_error else color),
    )
for item in zfs_jobs:
    row('ZFS JOB : ', seg(item, 'red'))
for item in zfs_warnings:
    row('ZFS WARN: ', seg(item, 'red'))

section('PHYSICAL DISKS / SMART / ENDURANCE EST.')
# DEVICE und SMART entfallen. Stattdessen wird der Modellname anhand des
# SMART-Zustands eingefaerbt. Seriennummern werden niemals abgekuerzt.
# Freie 76 Spalten werden dynamisch zwischen Modell und Seriennummer verteilt.
SERIAL_WIDTH = max([22] + [len(clean(d[1])) for d in disks])
MODEL_WIDTH = max(8, TEXT_WIDTH - SERIAL_WIDTH - 20)
row(seg(f"{'MODEL':<{MODEL_WIDTH}} {'SERIAL':<{SERIAL_WIDTH}} {'WEAR':>5} {'ON-Y':>5} {'LEFT-Y':>6}", 'cyan'))
for model, serial, wear, years, remain, health_color, wear_color in disks:
    row(
        seg(pad(model, MODEL_WIDTH), health_color),
        seg(f' {clean(serial):<{SERIAL_WIDTH}} '),
        seg(f'{wear:>5}', wear_color),
        seg(f' {years:>5} {remain:>6}')
    )
if not disks:
    row(seg('Keine physischen Datentraeger erkannt', 'orange'))
ROWS.append(('footer', f' {host} | Proxmox VE {version} | {now} '))

# Wrap colored text without any status symbols.
def wrap_segments(parts):
    lines, current, length = [], [], 0
    for text, color in parts:
        while text:
            space = TEXT_WIDTH - length
            if space <= 0:
                lines.append(current)
                current, length = [], 0
                space = TEXT_WIDTH
            if len(text) <= space:
                current.append((text, color))
                length += len(text)
                break
            if length and len(text) <= TEXT_WIDTH:
                lines.append(current)
                current, length = [], 0
                continue
            current.append((text[:space], color))
            length += space
            text = text[space:]
    if current or not lines:
        lines.append(current)
    return lines

def render_ansi():
    output = []
    yellow, white, cyan = COLORS['yellow'], COLORS['white'], COLORS['cyan']

    def border(left, fill, right):
        output.append(yellow + left + fill * (WIDTH + 2) + right + RESET)

    def content(parts):
        for wrapped in wrap_segments(parts):
            visible = sum(len(text) for text, _ in wrapped)
            line = yellow + '║' + white + ' '
            for text, color in wrapped:
                line += COLORS.get(color, white) + text
            output.append(
                line + white + ' ' * (WIDTH - visible) + ' '
                + yellow + '║' + RESET
            )

    border('╔', '═', '╗')
    for index, item in enumerate(ROWS):
        kind, value = item[:2]
        if index == 1:
            border('╠', '═', '╣')
        if kind == 'section':
            title = f' {value} '[:WIDTH + 1]
            output.append(
                yellow + '╟' + '─' + cyan + title + yellow
                + '─' * max(0, WIDTH + 1 - len(title)) + '╢' + RESET
            )
        elif kind == 'row':
            content(value)
        elif kind == 'footer':
            border('╠', '═', '╣')
            content([seg(value, 'yellow')])
    border('╚', '═', '╝')
    return '\n'.join(output) + '\n'


def render_mono():
    output = ['=' * (WIDTH + 4)]
    for item in ROWS:
        kind, value = item[:2]
        if kind == 'section':
            output.extend(('', value.upper(), '-' * (WIDTH + 4)))
        elif kind == 'row':
            for wrapped in wrap_segments(value):
                output.append(''.join(text for text, _ in wrapped))
        elif kind == 'footer':
            output.extend(('=' * (WIDTH + 4), value))
    output.append('=' * (WIDTH + 4))
    return ('\n'.join(output) + '\n').encode('ascii', 'replace').decode('ascii')

content = render_mono() if args.mono else render_ansi()
# Stage all destinations first; each replacement is atomic.
staged = []
try:
    for target in TARGETS:
        fd, temporary = tempfile.mkstemp(prefix='.proxmox-banner.', dir=os.path.dirname(target))
        staged.append((temporary, target))
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temporary, 0o644)
        os.chown(temporary, 0, 0)
    for temporary, target in staged:
        os.replace(temporary, target)
finally:
    for temporary, _ in staged:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
