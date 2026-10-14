#!/usr/bin/env bash
# Proxmox VE Login Banner - Norton Commander Style
# Default: /etc/issue + /etc/motd
# Options: --mono --no-issue --no-motd

set -euo pipefail

if (( EUID != 0 )); then
    echo "Bitte als root ausfuehren." >&2
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
import sys
import tempfile
from datetime import datetime

# ==========================================================
# PARAMETER
# ==========================================================

parser = argparse.ArgumentParser(
    description="Proxmox VE Norton Commander Login Banner"
)

parser.add_argument(
    "--mono",
    action="store_true",
    help="ASCII ohne Farben und Unicode"
)

parser.add_argument(
    "--no-issue",
    action="store_true",
    help="/etc/issue nicht aktualisieren"
)

parser.add_argument(
    "--no-motd",
    action="store_true",
    help="/etc/motd nicht aktualisieren"
)

args = parser.parse_args()

if args.no_issue and args.no_motd:
    parser.error("Beide Ausgabeziele wurden deaktiviert")

TARGETS = []

if not args.no_issue:
    TARGETS.append("/etc/issue")

if not args.no_motd:
    TARGETS.append("/etc/motd")

WIDTH = 76

# ==========================================================
# NORTON COMMANDER FARBSCHEMA
# ==========================================================

RESET = "\033[0m"

# Klassischer Norton Commander:
# Blauer Hintergrund mit hellen Farben

BLUE = "\033[44m"

WHITE = "\033[44;97m"
YELLOW = "\033[44;93m"
CYAN = "\033[44;96m"
GREEN = "\033[44;92m"
RED = "\033[44;91m"

BOLD_WHITE = "\033[1;44;97m"
BOLD_YELLOW = "\033[1;44;93m"
BOLD_CYAN = "\033[1;44;96m"
BOLD_GREEN = "\033[1;44;92m"
BOLD_RED = "\033[1;44;91m"

COLORS = {
    "normal": WHITE,
    "white": BOLD_WHITE,
    "yellow": BOLD_YELLOW,
    "cyan": BOLD_CYAN,
    "green": BOLD_GREEN,
    "red": BOLD_RED,
}

# ==========================================================
# HILFSFUNKTIONEN
# ==========================================================

def run(command, timeout=8):

    if not shutil.which(command[0]):
        return 127, ""

    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False
        )

        return result.returncode, result.stdout.strip()

    except (OSError, subprocess.TimeoutExpired):
        return 124, ""


def read_json(command, timeout=12):

    _, output = run(command, timeout)

    try:
        return json.loads(output)
    except (ValueError, TypeError):
        return {}


def number(value):

    if isinstance(value, (int, float)):
        return float(value)

    if isinstance(value, str):

        match = re.search(
            r"\d+(?:\.\d+)?",
            value.replace(",", "")
        )

        if match:
            return float(match.group())

    return None


def clean(value):

    return re.sub(
        r"[\x00-\x1f\x7f-\x9f]",
        "?",
        str(value)
    )


def pad(value, width):

    value = clean(value)

    if len(value) > width:
        return value[:width - 1] + "~"

    return value.ljust(width)


def segment(text, color="normal"):
    return (clean(text), color)


def status_color(value):

    value = str(value).upper()

    if value in (
        "OK",
        "ONLINE",
        "HEALTH_OK",
        "ACTIVE",
        "UP",
        "RUNNING",
        "NETZ"
    ):
        return "green"

    if value in (
        "WARN",
        "WARNING",
        "HEALTH_WARN",
        "UNKNOWN"
    ):
        return "yellow"

    return "red"


# ==========================================================
# SYSTEMINFORMATIONEN
# ==========================================================

_, hostname = run(["hostname", "-f"])

if not hostname:
    _, hostname = run(["hostname"])

_, pve_version = run(["pveversion"])

version = (
    pve_version.split("/", 1)[1].split("/", 1)[0]
    if "/" in pve_version
    else "?"
)

_, kernel = run(["uname", "-r"])

_, uptime = run(["uptime", "-p"])

uptime = uptime.removeprefix("up ") or "-"

timestamp = datetime.now().strftime(
    "%d.%m.%Y %H:%M"
)

# ==========================================================
# KERNELVERGLEICH
# ==========================================================

_, installed_output = run([
    "find",
    "/lib/modules",
    "-mindepth", "1",
    "-maxdepth", "1",
    "-type", "d",
    "-name", "*-pve",
    "-printf", "%f\n"
])

installed = [
    value
    for value in installed_output.splitlines()
    if value
]

latest = ""

if installed:

    try:
        result = subprocess.run(
            ["sort", "-V"],
            input="\n".join(installed) + "\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
            check=False
        )

        versions = result.stdout.splitlines()

        if versions:
            latest = versions[-1]

    except (OSError, subprocess.TimeoutExpired):
        pass

if not latest:
    kernel_status = "UNKNOWN"

elif latest == kernel:
    kernel_status = "OK"

else:
    kernel_status = f"REBOOT? -> {latest}"

# ==========================================================
# MEMORY
# ==========================================================

memory = {}

try:

    with open("/proc/meminfo") as file:

        for entry in file:

            key, _, value = entry.partition(":")

            match = re.search(
                r"\d+",
                value
            )

            if match:
                memory[key] = int(match.group())

except OSError:
    pass

mem_total = memory.get("MemTotal", 0)
mem_available = memory.get("MemAvailable", 0)

if mem_total:

    memory_text = (
        f"{mem_available / 1048576:.1f} GiB frei / "
        f"{mem_total / 1048576:.1f} GiB gesamt"
    )

    memory_percent = (
        100 * mem_available / mem_total
    )

else:
    memory_text = "UNKNOWN"
    memory_percent = 0

# ==========================================================
# SYSTEMLOAD
# ==========================================================

try:

    load1, load5, load15 = os.getloadavg()

    load_text = (
        f"{load1:.2f} / "
        f"{load5:.2f} / "
        f"{load15:.2f} (1/5/15 min)"
    )

except OSError:

    load_text = "UNKNOWN"

# ==========================================================
# IP ADRESSEN
# ==========================================================

_, ip_output = run([
    "ip",
    "-o",
    "-4",
    "addr",
    "show",
    "scope",
    "global"
])

ips = []

for entry in ip_output.splitlines():

    fields = entry.split()

    if len(fields) >= 4:

        ips.append(
            f"{fields[3]}({fields[1]})"
        )

# ==========================================================
# PHYSISCHE NETZWERKKARTEN
# ==========================================================

nics = []

for interface in sorted(
    os.listdir("/sys/class/net")
):

    device_path = (
        f"/sys/class/net/{interface}/device"
    )

    # Nur physische Interfaces
    if not os.path.exists(device_path):
        continue

    base = f"/sys/class/net/{interface}"

    carrier = None
    speed = "?"
    duplex = "?"

    try:
        with open(f"{base}/carrier") as file:
            carrier = file.read().strip()
    except OSError:
        pass

    try:
        with open(f"{base}/speed") as file:
            speed_raw = int(file.read().strip())

            if speed_raw >= 1000:
                speed = f"{speed_raw / 1000:g}G"
            elif speed_raw > 0:
                speed = f"{speed_raw}M"

    except (OSError, ValueError):
        pass

    try:
        with open(f"{base}/duplex") as file:
            duplex = file.read().strip().upper()

    except OSError:
        pass

    # Fallback ethtool
    if carrier is None or speed == "?":

        _, eth = run([
            "ethtool",
            interface
        ], timeout=3)

        if "Link detected: yes" in eth:
            carrier = "1"

        elif "Link detected: no" in eth:
            carrier = "0"

        match = re.search(
            r"Speed:\s*(\d+)Mb/s",
            eth
        )

        if match:

            mbits = int(match.group(1))

            if mbits >= 1000:
                speed = f"{mbits / 1000:g}G"
            else:
                speed = f"{mbits}M"

        match = re.search(
            r"Duplex:\s*(\w+)",
            eth
        )

        if match:
            duplex = match.group(1).upper()

    if carrier == "1":

        label = (
            f"{interface}[UP {speed}/{duplex}]"
        )

        color = "green"

    elif carrier == "0":

        label = f"{interface}[DOWN]"
        color = "red"

    else:

        label = f"{interface}[UNKNOWN]"
        color = "yellow"

    nics.append((label, color))

# ==========================================================
# VIRTUAL MACHINES / LXC
# ==========================================================

def get_guests(command, container=False):

    rc, output = run(
        command,
        timeout=10
    )

    if rc != 0:
        return []

    result = []

    for entry in output.splitlines()[1:]:

        fields = entry.split()

        if len(fields) < 3:
            continue

        if not fields[0].isdigit():
            continue

        vmid = fields[0]

        if container:

            status = fields[1]
            name = fields[-1]

        else:

            name = fields[1]
            status = fields[2]

        color = (
            "green"
            if status.lower() == "running"
            else "red"
        )

        result.append((
            f"{vmid}:{name}",
            color
        ))

    return result


vms = get_guests([
    "qm", "list"
])

lxcs = get_guests([
    "pct", "list"
], container=True)

# ==========================================================
# PROXMOX DATASTORES
# ==========================================================

storages = []

_, storage_output = run([
    "pvesm", "status"
], timeout=12)

for entry in storage_output.splitlines()[1:]:

    fields = entry.split()

    if len(fields) < 3:
        continue

    name = fields[0]

    if fields[2] == "active" and len(fields) >= 7:

        used = fields[6]

        percentage = number(used)

        if percentage is None:
            color = "yellow"

        elif percentage >= 90:
            color = "red"

        elif percentage >= 80:
            color = "yellow"

        else:
            color = "green"

    else:

        used = "OFF"
        color = "red"

    storages.append((
        name,
        used,
        color
    ))

# ==========================================================
# ZFS POOLS
# ==========================================================

zpools = []
zfs_jobs = []
zfs_warnings = []

if shutil.which("zpool"):

    rc, output = run([
        "zpool",
        "list",
        "-H",
        "-o",
        "name,health,capacity"
    ], timeout=10)

    for entry in output.splitlines():

        fields = entry.split()

        if len(fields) < 3:
            continue

        name, health, used = fields[:3]

        zpools.append((
            name,
            health,
            used
        ))

        # Poolstatus inklusive Scan/Trim
        rc, detail = run([
            "zpool",
            "status",
            name
        ], timeout=10)

        if rc != 0:

            zfs_warnings.append(
                f"{name}: Status nicht abrufbar"
            )

            continue

        # Scrub / Resilver / Trim
        for detail_line in detail.splitlines():

            current = detail_line.strip()
            lower = current.lower()

            if lower.startswith("scan:"):

                if (
                    "scrub in progress" in lower
                    or "resilver in progress" in lower
                ):

                    job = (
                        "RESILVER"
                        if "resilver" in lower
                        else "SCRUB"
                    )

                    zfs_jobs.append(
                        f"{name}: {job} RUNNING"
                    )

            elif lower.startswith("trim:"):

                if (
                    "in progress" in lower
                    or "trimming" in lower
                ):

                    zfs_jobs.append(
                        f"{name}: TRIM RUNNING"
                    )

        if health != "ONLINE":

            zfs_warnings.append(
                f"{name}: {health}"
            )

# ==========================================================
# PROXMOX CLUSTER
# ==========================================================

cluster = "Standalone"

cluster_exists = (
    os.path.exists("/etc/pve/corosync.conf")
    or os.path.exists("/etc/corosync/corosync.conf")
)

if cluster_exists:

    rc, output = run([
        "pvecm", "status"
    ], timeout=8)

    if rc != 0:

        cluster = "ERROR: Cluster nicht erreichbar"

    else:

        values = dict(
            (key.strip(), value.strip())
            for key, value in re.findall(
                r"^([^:\n]+):\s*(.+)$",
                output,
                re.M
            )
        )

        name = values.get("Name", "?")
        nodes = values.get("Nodes", "?")

        votes = values.get(
            "Total votes", "?"
        )

        expected = values.get(
            "Expected votes", "?"
        )

        quorum = (
            "OK"
            if values.get(
                "Quorate", ""
            ).lower() == "yes"
            else "ERROR"
        )

        cluster = (
            f"{name} | Nodes: {nodes} "
            f"| Votes: {votes}/{expected} "
            f"| Quorum: {quorum}"
        )

# ==========================================================
# CEPH STATUS
# ==========================================================

ceph = "nicht konfiguriert"
ceph_details = ""

if (
    os.path.exists("/etc/pve/ceph.conf")
    or os.path.exists("/etc/ceph/ceph.conf")
):

    data = read_json([
        "ceph",
        "status",
        "--format",
        "json"
    ], timeout=10)

    if not data:

        ceph = "ERROR: Ceph nicht erreichbar"

    else:

        health_data = data.get("health") or {}

        health = health_data.get(
            "status", "UNKNOWN"
        )

        osd = (
            (data.get("osdmap") or {})
            .get("osdmap") or {}
        )

        up = osd.get(
            "num_up_osds", "?"
        )

        total = osd.get(
            "num_osds", "?"
        )

        inside = osd.get(
            "num_in_osds", "?"
        )

        mon = len(
            data.get("quorum_names") or []
        )

        ceph = (
            f"{health} | "
            f"OSD: {up}/{total} "
            f"| IN: {inside} "
            f"| MON: {mon}"
        )

        if health != "HEALTH_OK":

            checks = (
                health_data.get("checks") or {}
            )

            ceph_details = ", ".join(
                list(checks)[:3]
            )

# ==========================================================
# MULTIPATH
# ==========================================================

multipath = None
multipath_details = ""

if (
    shutil.which("multipath")
    or shutil.which("multipathd")
):

    rc, state = run([
        "systemctl",
        "is-active",
        "multipathd"
    ], timeout=4)

    if rc != 0 or state != "active":

        multipath = "ERROR: multipathd nicht aktiv"

    else:

        rc, output = run([
            "multipathd",
            "show",
            "paths",
            "raw",
            "format",
            "%d %t %T %o"
        ], timeout=8)

        if rc != 0:

            multipath = "ERROR: Pfade nicht abrufbar"

        else:

            total = 0
            failed = []

            for entry in output.splitlines():

                fields = entry.split()

                if len(fields) != 4:
                    continue

                device, dm, checker, online = fields

                if device.lower() in (
                    "dev", "device"
                ):
                    continue

                total += 1

                if (
                    dm.lower() == "failed"
                    or checker.lower() in (
                        "faulty", "shaky"
                    )
                    or online.lower() == "offline"
                ):

                    failed.append(device)

            if failed:

                multipath = (
                    f"ERROR: {len(failed)}/{total} "
                    "Pfade defekt"
                )

                multipath_details = ", ".join(
                    failed
                )

            else:

                multipath = (
                    f"OK ({total} Pfade)"
                )

            # Multipath-Maps kontrollieren
            map_rc, maps = run([
                "multipathd",
                "show",
                "maps",
                "raw",
                "format",
                "%n %t"
            ], timeout=8)

            if map_rc == 0:

                inactive = []

                for entry in maps.splitlines():

                    fields = entry.split()

                    if (
                        len(fields) >= 2
                        and fields[1].lower() != "active"
                    ):

                        inactive.append(fields[0])

                if inactive:

                    multipath += (
                        f" | ERROR: {len(inactive)} "
                        "Maps inaktiv"
                    )

                    multipath_details += (
                        "; " if multipath_details else ""
                    ) + ", ".join(inactive)

# ==========================================================
# NUT / USV
# ==========================================================

def nut_targets():

    result = []

    config_files = [
        "/etc/nut/upsmon.conf"
    ] + sorted(
        glob.glob(
            "/etc/nut/upsmon.conf.d/*.conf"
        )
    )

    for filename in config_files:

        try:

            with open(
                filename,
                encoding="utf-8",
                errors="replace"
            ) as file:

                for entry in file:

                    try:

                        fields = shlex.split(
                            entry,
                            comments=True
                        )

                    except ValueError:
                        continue

                    if (
                        len(fields) >= 2
                        and fields[0].upper() == "MONITOR"
                    ):

                        result.append(fields[1])

        except OSError:
            pass

    if not result:

        rc, output = run([
            "upsc", "-l"
        ], timeout=5)

        if rc == 0:

            result = [
                f"{name.strip()}@localhost"
                for name in output.splitlines()
                if name.strip()
            ]

    return list(dict.fromkeys(result))


def read_ups(target):

    rc, output = run([
        "upsc", target
    ], timeout=6)

    if rc != 0 or not output:

        return (
            f"{target}: ERROR",
            "red"
        )

    values = {}

    for entry in output.splitlines():

        key, colon, value = entry.partition(":")

        if colon:

            values[key.strip()] = value.strip()

    raw = values.get(
        "ups.status", ""
    )

    flags = set(raw.split())

    if flags.intersection({
        "FSD", "LB", "RB"
    }):

        status = f"WARN ({raw})"
        color = "red"

    elif "OB" in flags:

        status = f"BATTERIE ({raw})"
        color = "red"

    elif "OL" in flags:

        status = f"NETZ ({raw})"
        color = "green"

    else:

        status = raw or "UNKNOWN"
        color = "yellow"

    details = [
        f"{target}: {status}"
    ]

    charge = values.get(
        "battery.charge"
    )

    if charge:

        details.append(
            f"Akku {charge}%"
        )

    runtime = number(
        values.get("battery.runtime")
    )

    if runtime is not None:

        details.append(
            f"Rest {runtime / 60:.0f} min"
        )

    load = values.get("ups.load")

    if load:

        details.append(
            f"Last {load}%"
        )

    return " | ".join(details), color


ups_lines = []

if shutil.which("upsc"):

    targets = nut_targets()

    if targets:

        for target in targets[:10]:

            ups_lines.append(
                read_ups(target)
            )

    else:

        ups_lines.append((
            "Keine USV gefunden",
            "yellow"
        ))

else:

    ups_lines.append((
        "NUT nicht installiert",
        "yellow"
    ))

# ==========================================================
# SMART / SSD WEAROUT
# ==========================================================

def smart_values(data):

    nvme = (
        data.get(
            "nvme_smart_health_information_log"
        ) or {}
    )

    hours = number(
        nvme.get("power_on_hours")
    )

    wear = number(
        nvme.get("percentage_used")
    )

    if hours is None:

        hours = number(
            (data.get("power_on_time") or {})
            .get("hours")
        )

    attributes = (
        (data.get("ata_smart_attributes") or {})
        .get("table") or []
    )

    # SMART 9 - Power On Hours
    if hours is None:

        for attr in attributes:

            if attr.get("id") == 9:

                hours = number(
                    (attr.get("raw") or {})
                    .get("value")
                )

                break

    # SSD Wearout:
    # 177 Wear Leveling Count
    # 202 Lifetime Used
    # 231 SSD Life Left
    # 233 Media Wearout Indicator

    if wear is None:

        for attr_id in (233, 177, 231, 202):

            for attr in attributes:

                if attr.get("id") != attr_id:
                    continue

                name = str(
                    attr.get("name", "")
                ).lower()

                norm = number(
                    attr.get("value")
                )

                raw = number(
                    (attr.get("raw") or {})
                    .get("value")
                )

                if attr_id == 233:

                    valid = any(
                        key in name
                        for key in (
                            "wearout",
                            "life_left",
                            "lifetime_remain"
                        )
                    )

                    if (
                        valid
                        and norm is not None
                        and 0 <= norm <= 100
                    ):

                        wear = 100 - norm

                elif attr_id == 177:

                    if (
                        "wear_level" in name
                        and norm is not None
                        and 0 <= norm <= 100
                    ):

                        wear = 100 - norm

                elif attr_id == 231:

                    valid = any(
                        key in name
                        for key in (
                            "life_left",
                            "lifetime_remain",
                            "ssd_life"
                        )
                    )

                    if (
                        valid
                        and norm is not None
                        and 0 <= norm <= 100
                    ):

                        wear = 100 - norm

                elif attr_id == 202:

                    if (
                        "lifetime" in name
                        and "used" in name
                        and raw is not None
                        and 0 <= raw <= 100
                    ):

                        wear = raw

                    elif (
                        "lifetime" in name
                        and "remain" in name
                        and norm is not None
                        and 0 <= norm <= 100
                    ):

                        wear = 100 - norm

                if wear is not None:
                    break

            if wear is not None:
                break

    wear_text = (
        f"{wear:.0f}%"
        if wear is not None
        else "-"
    )

    years_text = (
        f"{hours / 8766:.1f}"
        if hours is not None
        else "-"
    )

    return wear_text, years_text, wear


# ==========================================================
# SMART GESUNDHEIT
# ==========================================================

def smart_health(data, wear):

    if not data:
        return "UNKNOWN", "yellow"

    smart_status = data.get(
        "smart_status"
    ) or {}

    passed = smart_status.get("passed")

    if passed is False:
        return "BAD", "red"

    critical = False

    # ATA SMART
    attributes = (
        (data.get("ata_smart_attributes") or {})
        .get("table") or []
    )

    # Kritische SMART-Attribute
    critical_ids = {
        5,      # Reallocated sectors
        187,    # Reported uncorrectable
        197,    # Current pending sectors
        198     # Offline uncorrectable
    }

    for attr in attributes:

        if attr.get("id") not in critical_ids:
            continue

        raw = number(
            (attr.get("raw") or {})
            .get("value")
        )

        if raw is not None and raw > 0:
            critical = True

    # SMART Attribute mit WHEN_FAILED
    for attr in attributes:

        when_failed = attr.get(
            "when_failed"
        )

        if when_failed and str(
            when_failed
        ).strip() not in ("", "-", "None"):

            critical = True

    # NVMe
    nvme = (
        data.get(
            "nvme_smart_health_information_log"
        ) or {}
    )

    nvme_warning = nvme.get(
        "critical_warning", 0
    )

    try:

        if isinstance(nvme_warning, dict):
            if any(nvme_warning.values()):
                critical = True

        elif int(nvme_warning) != 0:
            critical = True

    except (TypeError, ValueError):
        pass

    media_errors = number(
        nvme.get("media_errors")
    )

    if (
        media_errors is not None
        and media_errors > 0
    ):
        critical = True

    if wear is not None and wear >= 100:
        critical = True

    if critical:
        return "BAD", "red"

    if passed is True:
        return "OK", "green"

    if attributes or nvme:
        return "OK", "green"

    return "UNKNOWN", "yellow"


# ==========================================================
# PHYSISCHE DATENTRAEGER
# ==========================================================

disks = []

block_devices = read_json([
    "lsblk",
    "-J",
    "-d",
    "-o",
    "NAME,TYPE,MODEL,SERIAL"
])

for disk in block_devices.get(
    "blockdevices", []
):

    name = str(
        disk.get("name") or ""
    )

    if disk.get("type") != "disk":
        continue

    # Virtuelle Blockdevices ausschliessen
    if name.startswith((
        "zd",
        "loop",
        "ram",
        "nbd",
        "rbd",
        "dm-",
        "zram"
    )):
        continue

    smart = read_json([
        "smartctl",
        "-a",
        "-j",
        f"/dev/{name}"
    ], timeout=15)

    model = str(
        disk.get("model")
        or smart.get("model_name")
        or "unknown"
    ).strip()

    serial = str(
        disk.get("serial")
        or smart.get("serial_number")
        or "-"
    ).strip()

    wear_text, years, wear = smart_values(
        smart
    )

    health, color = smart_health(
        smart, wear
    )

    disks.append((
        name,
        model,
        serial,
        wear_text,
        years,
        health,
        color
    ))

# ==========================================================
# AUSGABE AUFBAUEN
# ==========================================================

ROWS = []

def row(*parts):

    result = []

    for part in parts:

        if isinstance(part, tuple):
            result.append(part)

        else:
            result.append(
                segment(part)
            )

    ROWS.append(("row", result))


def section(title):

    ROWS.append((
        "section",
        clean(title)
    ))


def guest_row(label, guests):

    parts = [
        segment(
            f"{label:<8}: "
        )
    ]

    if guests:

        for index, (name, color) in enumerate(guests):

            if index:
                parts.append(
                    segment(", ")
                )

            # Nur VMID und Name werden eingefaerbt.
            # Kein zusaetzliches ON/OFF erforderlich.
            parts.append(
                segment(name, color)
            )

    else:

        parts.append(
            segment("-")
        )

    row(*parts)


# ==========================================================
# SYSTEM
# ==========================================================

row(
    segment(
        f"PROXMOX VE {version}",
        "yellow"
    ),
    segment(
        f" | {hostname}",
        "white"
    )
)

row(
    f"IP      : {', '.join(ips) if ips else '-'}"
)

row(
    "Kernel  : ",
    segment(
        kernel,
        "white"
    ),
    " [",
    segment(
        kernel_status,
        status_color(
            "OK"
            if kernel_status == "OK"
            else "WARN"
            if kernel_status == "UNKNOWN"
            or kernel_status.startswith("REBOOT?")
            else "ERROR"
        )
    ),
    "]"
)

row(
    f"Uptime  : {uptime} | Update: {timestamp}"
)

row(
    "Memory  : ",
    segment(
        memory_text,
        "green"
        if memory_percent >= 20
        else "yellow"
        if memory_percent >= 10
        else "red"
    )
)

row(
    "Load    : ",
    segment(
        load_text,
        "white"
    )
)

# ==========================================================
# NETZWERKKARTEN
# ==========================================================

section("PHYSICAL NETWORK INTERFACES")

if nics:

    parts = [
        segment("NICs    : ")
    ]

    for index, (label, color) in enumerate(nics):

        if index:
            parts.append(
                segment(", ")
            )

        parts.append(
            segment(label, color)
        )

    row(*parts)

else:

    row(
        "NICs    : -"
    )

# ==========================================================
# VMS / LXCS / CLUSTER
# ==========================================================

section("VIRTUAL MACHINES / CONTAINERS")

guest_row("VMs", vms)
guest_row("LXCs", lxcs)

section("CLUSTER / CEPH / MULTIPATH")

cluster_color = (
    "red"
    if "ERROR" in cluster
    else "green"
    if "Quorum: OK" in cluster
    else "white"
)

row(
    "Cluster : ",
    segment(
        cluster,
        cluster_color
    )
)

ceph_color = (
    "green"
    if "HEALTH_OK" in ceph
    else "yellow"
    if "HEALTH_WARN" in ceph
    else "red"
    if "ERROR" in ceph
    or "HEALTH_ERR" in ceph
    else "white"
)

row(
    "Ceph    : ",
    segment(
        ceph,
        ceph_color
    )
)

if ceph_details:

    row(
        "Ceph    : ",
        segment(
            ceph_details,
            "red"
        )
    )

if multipath is not None:

    row(
        "MPath   : ",
        segment(
            multipath,
            "red"
            if "ERROR" in multipath
            else "green"
        )
    )

    if multipath_details:

        row(
            "MPath   : ",
            segment(
                multipath_details,
                "red"
            )
        )

# ==========================================================
# NUT / USV
# ==========================================================

section("UPS / NUT")

for text, color in ups_lines:

    row(
        "UPS     : ",
        segment(
            text,
            color
        )
    )

# ==========================================================
# DATASTORES / ZFS
# ==========================================================

section("DATASTORES / ZFS POOLS")

row(
    segment(
        f"{'DATASTORES (USED)':<35}",
        "cyan"
    ),
    segment(
        "ZFS POOLS (USED)",
        "cyan"
    )
)

count = max(
    len(storages),
    len(zpools),
    1
)

for index in range(count):

    parts = []

    if index < len(storages):

        name, used, color = storages[index]

        parts.extend([
            segment(
                pad(name, 22)
            ),
            segment(
                f"{used:>6}",
                color
            ),
            segment(
                " " * 7
            )
        ])

    else:

        parts.append(
            segment(" " * 35)
        )

    if index < len(zpools):

        name, health, used = zpools[index]

        parts.extend([
            segment(
                pad(name, 13)
            ),
            segment(
                f"{health:<10}",
                status_color(health)
            ),
            segment(
                f"{used:>5}"
            )
        ])

    row(*parts)

# ZFS Scrub/Trim/Resilver
for job in zfs_jobs:

    row(
        "ZFS JOB : ",
        segment(
            job,
            "red"
        )
    )

for warning in zfs_warnings:

    row(
        "ZFS WARN: ",
        segment(
            warning,
            "red"
        )
    )

# ==========================================================
# PHYSICAL DISKS
# ==========================================================

section("PHYSICAL DISKS / SMART")

row(
    segment(
        f"{'DEVICE':<9} "
        f"{'MODEL':<16} "
        f"{'SERIAL':<22} "
        f"{'WEAR':>5} "
        f"{'YEARS':>5} "
        f"{'SMART':>7}",
        "cyan"
    )
)

for (
    name,
    model,
    serial,
    wear,
    years,
    health,
    color
) in disks:

    serial_preview = (
        serial
        if len(serial) <= 22
        else serial[:21] + "~"
    )

    row(
        segment(
            pad(name, 9),
            color
        ),
        segment(
            f" {pad(model, 16)} "
            f"{serial_preview:<22} "
            f"{wear:>5} "
            f"{years:>5} "
        ),
        segment(
            f"{health:>7}",
            color
        )
    )

    if len(serial) > 22:

        row(
            f"Serial {name}: {serial}"
        )

if not disks:

    row(
        segment(
            "Keine physischen Datentraeger erkannt",
            "yellow"
        )
    )

# ==========================================================
# FOOTER
# ==========================================================

ROWS.append((
    "footer",
    f" {hostname} | Proxmox VE {version} | {timestamp} "
))

# ==========================================================
# TEXTZEILEN UMBRECHEN
# ==========================================================

def wrap_segments(parts):

    lines = []
    current = []
    length = 0

    def flush():

        nonlocal current, length

        lines.append(current)

        current = []
        length = 0

    for text, color in parts:

        if not text:
            continue

        # Lange Texte notfalls teilen
        while text:

            available = WIDTH - length

            if available <= 0:

                flush()
                available = WIDTH

            if len(text) <= available:

                current.append(
                    (text, color)
                )

                length += len(text)
                break

            # Moeglichst vor dem naechsten Token umbrechen
            if (
                length > 0
                and len(text) <= WIDTH
            ):

                flush()
                continue

            chunk = text[:available]

            current.append(
                (chunk, color)
            )

            length += len(chunk)
            text = text[available:]

            if text:
                flush()

    if current or not lines:
        lines.append(current)

    return lines

# ==========================================================
# ANSI / NORTON COMMANDER RENDERER
# ==========================================================

def render_ansi():

    output = []

    def border(character_left, fill, character_right):

        output.append(
            BOLD_YELLOW
            + character_left
            + fill * (WIDTH + 2)
            + character_right
            + RESET
        )

    def content(parts):

        for wrapped in wrap_segments(parts):

            visible = sum(
                len(text)
                for text, _ in wrapped
            )

            line = (
                BOLD_YELLOW
                + "║"
                + WHITE
                + " "
            )

            for text, color in wrapped:

                line += (
                    COLORS.get(color, WHITE)
                    + text
                )

            # Wieder blauen Hintergrund und weisse Schrift
            line += (
                WHITE
                + " " * (WIDTH - visible)
                + " "
                + BOLD_YELLOW
                + "║"
                + RESET
            )

            output.append(line)

    def heading(title):

        text = f" {title} "

        available = WIDTH + 2

        if len(text) > available:
            text = text[:available]

        remaining = available - len(text)

        output.append(
            BOLD_YELLOW
            + "╟"
            + "─"
            + BOLD_CYAN
            + text
            + BOLD_YELLOW
            + "─" * max(0, remaining - 1)
            + "╢"
            + RESET
        )

    border("╔", "═", "╗")

    for index, (kind, value) in enumerate(ROWS):

        if index == 1:

            border("╠", "═", "╣")

        if kind == "section":

            heading(value)

        elif kind == "row":

            content(value)

        elif kind == "footer":

            border("╠", "═", "╣")

            content([
                segment(
                    value,
                    "yellow"
                )
            ])

    border("╚", "═", "╝")

    return "\n".join(output) + "\n"

# ==========================================================
# MONO ASCII RENDERER
# ==========================================================

def render_mono():

    output = []

    output.append(
        "=" * (WIDTH + 4)
    )

    for kind, value in ROWS:

        if kind == "section":

            output.append("")

            output.append(
                value.upper()
            )

            output.append(
                "-" * (WIDTH + 4)
            )

        elif kind == "row":

            parts = wrap_segments(value)

            for line in parts:

                output.append(
                    "".join(
                        text
                        for text, _ in line
                    )
                )

        elif kind == "footer":

            output.append(
                "=" * (WIDTH + 4)
            )

            output.append(value)

    output.append(
        "=" * (WIDTH + 4)
    )

    return "\n".join(output) + "\n"

# ==========================================================
# AUSGABE ERZEUGEN
# ==========================================================

if args.mono:

    content = render_mono()

else:

    content = render_ansi()

# ==========================================================
# /etc/issue UND /etc/motd SCHREIBEN
# ==========================================================

staged = []

try:

    # Beide Zieldateien zuerst vollstaendig vorbereiten
    for target in TARGETS:

        directory = os.path.dirname(target)

        fd, temp = tempfile.mkstemp(
            prefix=".proxmox-banner.",
            dir=directory
        )

        staged.append((
            temp,
            target
        ))

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
            newline="\n"
        ) as file:

            file.write(content)

            file.flush()
            os.fsync(
                file.fileno()
            )

        os.chmod(
            temp,
            0o644
        )

        os.chown(
            temp,
            0,
            0
        )

    # Einzelne Dateien atomar ersetzen
    for temp, target in staged:

        os.replace(
            temp,
            target
        )

finally:

    for temp, _ in staged:

        if os.path.exists(temp):

            os.unlink(temp)

PY
