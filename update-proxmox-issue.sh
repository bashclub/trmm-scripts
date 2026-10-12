#!/usr/bin/env bash
# Proxmox VE Login Banner: /etc/issue + /etc/motd
# Default: ANSI/Unicode; --mono: ASCII without colors
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
import sys
import tempfile
import textwrap
from datetime import datetime

parser = argparse.ArgumentParser(description='Proxmox Konsolenbanner aktualisieren')
parser.add_argument('--mono', action='store_true', help='ASCII ohne Farben/Rahmen')
parser.add_argument('--no-motd', action='store_true', help='/etc/motd nicht schreiben')
parser.add_argument('--no-issue', action='store_true', help='/etc/issue nicht schreiben')
args = parser.parse_args()
if args.no_motd and args.no_issue:
    parser.error('--no-motd und --no-issue schliessen beide Ziele aus')

WIDTH = 76
TARGETS = []
if not args.no_issue:
    TARGETS.append('/etc/issue')
if not args.no_motd:
    TARGETS.append('/etc/motd')


def run(argv, timeout=8):
    if not shutil.which(argv[0]):
        return 127, ''
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           errors='replace', timeout=timeout, check=False)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 124, ''


def read_json(argv, timeout=12):
    _, output = run(argv, timeout)
    try:
        return json.loads(output)
    except (ValueError, TypeError):
        return {}


def clean(value):
    return re.sub(r'[\x00-\x1f\x7f-\x9f]', '?', str(value))


def number(value):
    if isinstance(value, (float, int)):
        return float(value)
    if isinstance(value, str):
        m = re.search(r'\d+(?:\.\d+)?', value.replace(',', ''))
        if m:
            return float(m.group())
    return None


def pad(value, width):
    value = clean(value)
    return (value[:width - 1] + '~') if len(value) > width else value.ljust(width)


# ----------------------------------------------------------
# SMART: NVMe, SATA-Attribute 177/202/231/233
# ----------------------------------------------------------

def smart_values(data):
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
        for attr_id in (233, 177, 231, 202):
            for attr in attrs:
                if attr.get('id') != attr_id:
                    continue
                name = str(attr.get('name', '')).lower()
                norm = number(attr.get('value'))
                raw = number((attr.get('raw') or {}).get('value'))

                if attr_id == 233 and any(
                    x in name for x in ('wearout', 'life_left', 'lifetime_remain')
                ):
                    if norm is not None and 0 <= norm <= 100:
                        wear = 100 - norm
                elif attr_id == 177 and 'wear_level' in name:
                    if norm is not None and 0 <= norm <= 100:
                        wear = 100 - norm
                elif attr_id == 231 and any(
                    x in name for x in ('life_left', 'lifetime_remain', 'ssd_life')
                ):
                    if norm is not None and 0 <= norm <= 100:
                        wear = 100 - norm
                elif attr_id == 202:
                    # Vendor-specific: RAW means used only if name explicitly says so.
                    if 'lifetime' in name and 'used' in name:
                        if raw is not None and 0 <= raw <= 100:
                            wear = raw
                    elif 'lifetime' in name and 'remain' in name:
                        if norm is not None and 0 <= norm <= 100:
                            wear = 100 - norm
                if wear is not None:
                    break
            if wear is not None:
                break

    wear_text = f'{wear:.0f}%' if wear is not None else '-'
    years_text = f'{hours / 8766:.1f}' if hours is not None else '-'
    return wear_text, years_text


# ----------------------------------------------------------
# SYSTEM, KERNEL, NETZWERK
# ----------------------------------------------------------

_, host = run(['hostname', '-f'])
if not host:
    _, host = run(['hostname'])
_, version_info = run(['pveversion'])
version = (version_info.split('/', 1)[1].split('/', 1)[0]
           if '/' in version_info else '?')
_, kernel = run(['uname', '-r'])
_, uptime = run(['uptime', '-p'])
uptime = uptime.removeprefix('up ') or '-'
_, installed_raw = run([
    'find', '/lib/modules', '-mindepth', '1', '-maxdepth', '1',
    '-type', 'd', '-name', '*-pve', '-printf', '%f\n'
])
installed = [s for s in installed_raw.splitlines() if s]
latest = ''
if installed:
    try:
        p = subprocess.run(['sort', '-V'], input='\n'.join(installed),
                           text=True, capture_output=True, timeout=3,
                           check=False)
        latest = p.stdout.splitlines()[-1] if p.stdout.splitlines() else ''
    except (OSError, subprocess.TimeoutExpired):
        pass
kernel_status = ('UNKNOWN' if not latest else 'OK' if latest == kernel
                 else f'REBOOT? -> {latest}')
_, ip_output = run(['ip', '-o', '-4', 'addr', 'show', 'scope', 'global'])
ips = []
for ip_line in ip_output.splitlines():
    parts = ip_line.split()
    if len(parts) >= 4:
        ips.append(f'{parts[3]}({parts[1]})')


# ----------------------------------------------------------
# GASTSYSTEME
# ----------------------------------------------------------

def guest_list(command, container=False):
    _, result = run(command, timeout=10)
    guests = []
    for line in result.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3 and parts[0].isdigit():
            name = parts[-1] if container else parts[1]
            guests.append(f'{parts[0]}:{name}')
    return ', '.join(guests) or '-'


vms = guest_list(['qm', 'list'])
lxcs = guest_list(['pct', 'list'], container=True)


# ----------------------------------------------------------
# DATASTORES UND ZFS
# ----------------------------------------------------------

_, storage_output = run(['pvesm', 'status'], timeout=12)
storages = []
for line in storage_output.splitlines()[1:]:
    parts = line.split()
    if len(parts) >= 3:
        usage = (parts[6] if len(parts) >= 7 and parts[2] == 'active'
                 else 'OFF')
        storages.append((parts[0], usage))

zpools = []
zfs_warning = ''
if shutil.which('zpool'):
    _, zpool_output = run(['zpool', 'list', '-H', '-o',
                           'name,health,capacity'])
    for line in zpool_output.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            zpools.append((parts[0], parts[1], parts[2]))
    if zpools:
        rc, zcheck = run(['zpool', 'status', '-x'], timeout=10)
        if rc != 0:
            zfs_warning = 'ZFS-Status nicht abrufbar'
        elif zcheck != 'all pools are healthy':
            zfs_warning = next((x.strip() for x in zcheck.splitlines()
                                if x.strip()), 'ZFS-Warnung')


# ----------------------------------------------------------
# PROXMOX CLUSTER
# ----------------------------------------------------------

cluster = 'Standalone'
if (os.path.exists('/etc/pve/corosync.conf')
        or os.path.exists('/etc/corosync/corosync.conf')):
    rc, info = run(['pvecm', 'status'], timeout=8)
    if rc != 0:
        cluster = 'ERROR: pvecm status nicht erreichbar'
    else:
        fields = dict((key.strip(), value.strip())
                      for key, value in re.findall(
                          r'^([^:\n]+):\s*(.+)$', info, re.M))
        name = fields.get('Name', '?')
        nodes = fields.get('Nodes', '?')
        votes = fields.get('Total votes', '?')
        expected = fields.get('Expected votes', '?')
        quorum = ('OK' if fields.get('Quorate', '').lower() == 'yes'
                  else 'ERROR')
        cluster = (f'{name} | Nodes: {nodes} | Votes: {votes}/{expected} '
                   f'| Quorum: {quorum}')


# ----------------------------------------------------------
# CEPH
# ----------------------------------------------------------

ceph = 'nicht konfiguriert'
ceph_extra = ''
if (os.path.exists('/etc/pve/ceph.conf')
        or os.path.exists('/etc/ceph/ceph.conf')):
    if not shutil.which('ceph'):
        ceph = 'ERROR: Ceph-CLI fehlt'
    else:
        data = read_json(['ceph', 'status', '--format', 'json'], timeout=10)
        if not data:
            ceph = 'ERROR: Ceph-Status nicht erreichbar'
        else:
            health = data.get('health') or {}
            status = health.get('status', 'UNKNOWN')
            osd = (data.get('osdmap') or {}).get('osdmap') or {}
            up = osd.get('num_up_osds', '?')
            total = osd.get('num_osds', '?')
            inside = osd.get('num_in_osds', '?')
            mon = len(data.get('quorum_names') or [])
            ceph = (f'{status} | OSD up/total: {up}/{total} '
                    f'| in: {inside} | MON quorum: {mon}')
            if status != 'HEALTH_OK':
                ceph_extra = ', '.join(
                    list((health.get('checks') or {}).keys())[:3])


# ----------------------------------------------------------
# MULTIPATH: NUR WENN INSTALLIERT
# ----------------------------------------------------------

mpath = None
mpath_extra = ''
if shutil.which('multipathd') or shutil.which('multipath'):
    if not shutil.which('multipathd'):
        mpath = 'ERROR: multipathd fehlt'
    else:
        rc, state = run(['systemctl', 'is-active', 'multipathd'], timeout=4)
        if rc != 0 or state != 'active':
            mpath = 'ERROR: multipathd nicht aktiv'
        else:
            rc, path_output = run([
                'multipathd', 'show', 'paths', 'raw',
                'format', '%d %t %T %o'
            ], timeout=8)
            if rc != 0:
                mpath = 'ERROR: Multipath-Pfade nicht abrufbar'
            else:
                total = 0
                broken = []
                for line in path_output.splitlines():
                    parts = line.split()
                    if len(parts) != 4 or parts[0].lower() in ('dev', 'device'):
                        continue
                    device, dmstate, checker, online = parts
                    total += 1
                    if (dmstate.lower() == 'failed'
                            or checker.lower() in ('faulty', 'shaky')
                            or online.lower() == 'offline'):
                        broken.append(device)
                mpath = (f'ERROR: {len(broken)}/{total} Pfade defekt'
                         if broken else f'OK ({total} Pfade)')
                if broken:
                    mpath_extra = ', '.join(broken)

                rc, map_output = run([
                    'multipathd', 'show', 'maps', 'raw',
                    'format', '%n %t'
                ], timeout=8)
                if rc == 0:
                    inactive = []
                    for line in map_output.splitlines():
                        fields = line.split()
                        if len(fields) >= 2 and fields[1].lower() != 'active':
                            inactive.append(fields[0])
                    if inactive:
                        mpath += f' | ERROR: {len(inactive)} Maps inaktiv'
                        mpath_extra += ('; ' if mpath_extra else '') + ', '.join(inactive)


# ----------------------------------------------------------
# NUT USV: upsmon.conf ODER LOKALE USV-LISTE
# ----------------------------------------------------------

def nut_targets():
    """Prioritaet: MONITOR-Eintraege, sonst lokal konfigurierte UPS."""
    items = []
    config_files = ['/etc/nut/upsmon.conf'] + sorted(
        glob.glob('/etc/nut/upsmon.conf.d/*.conf'))
    for filename in config_files:
        try:
            with open(filename, encoding='utf-8', errors='replace') as f:
                for line in f:
                    try:
                        tokens = shlex.split(line, comments=True)
                    except ValueError:
                        continue
                    if len(tokens) >= 2 and tokens[0].upper() == 'MONITOR':
                        items.append(tokens[1])
        except OSError:
            pass

    if not items:
        rc, local = run(['upsc', '-l'], timeout=5)
        if rc == 0:
            items += [f'{name.strip()}@localhost'
                      for name in local.splitlines() if name.strip()]
    return list(dict.fromkeys(items))


def read_ups(target):
    rc, data = run(['upsc', target], timeout=6)
    if rc != 0 or not data:
        return f'{target}: ERROR nicht erreichbar'
    fields = {}
    for line in data.splitlines():
        key, colon, value = line.partition(':')
        if colon:
            fields[key.strip()] = value.strip()
    rawstatus = fields.get('ups.status', '')
    flags = set(rawstatus.split())
    if not rawstatus:
        status = 'UNKNOWN'
    elif 'FSD' in flags or 'LB' in flags or 'RB' in flags:
        status = f'WARN ({rawstatus})'
    elif 'OB' in flags:
        status = f'BATTERIE ({rawstatus})'
    elif 'OL' in flags:
        status = f'NETZ ({rawstatus})'
    else:
        status = rawstatus

    details = [f'{target}: {status}']
    charge = fields.get('battery.charge')
    if charge:
        details.append(f'Akku {charge}%')
    runtime = number(fields.get('battery.runtime'))
    if runtime is not None:
        details.append(f'Restlaufzeit {runtime / 60:.0f} min')
    load = fields.get('ups.load')
    if load:
        details.append(f'Last {load}%')
    return ' | '.join(details)


ups_lines = []
if not shutil.which('upsc'):
    ups_lines = ['NUT nicht installiert']
else:
    targets = nut_targets()
    if not targets:
        ups_lines = ['NUT: keine USV gefunden (upsc -l / upsmon.conf)']
    else:
        ups_lines = [read_ups(item) for item in targets[:10]]
        if len(targets) > 10:
            ups_lines.append(f'{len(targets) - 10} weitere USV nicht angezeigt')


# ----------------------------------------------------------
# PHYSISCHE DATENTRAEGER + SERIAL
# ----------------------------------------------------------

disk_rows = []
blocks = read_json(['lsblk', '-J', '-d', '-o', 'NAME,TYPE,MODEL,SERIAL'])
for disk in blocks.get('blockdevices', []):
    name = str(disk.get('name') or '')
    if disk.get('type') != 'disk':
        continue
    if name.startswith(('zd', 'loop', 'ram', 'nbd', 'rbd', 'dm-', 'zram')):
        continue
    smart = read_json(['smartctl', '-a', '-j', f'/dev/{name}'], timeout=15)
    model = str(disk.get('model') or smart.get('model_name') or 'unknown').strip()
    serial = str(disk.get('serial') or smart.get('serial_number') or '-').strip()
    wear, years = smart_values(smart)
    disk_rows.append((name, model, serial, wear, years))


# ----------------------------------------------------------
# INHALT FUER BEIDE DATEIEN
# ----------------------------------------------------------

rows = []
def line(value=''):
    rows.append(('text', clean(value)))

def section(name):
    rows.append(('section', clean(name)))

stamp = datetime.now().strftime('%d.%m.%Y %H:%M')
line(f'PROXMOX VE {version} | {host}')
line(f'IP      : {", ".join(ips) if ips else "-"}')
line(f'Kernel  : {kernel} [{kernel_status}]')
line(f'Uptime  : {uptime} | Update: {stamp}')

section('GAESTE / CLUSTER')
line(f'VMs     : {vms}')
line(f'LXCs    : {lxcs}')
line(f'Cluster : {cluster}')
line(f'Ceph    : {ceph}')
if ceph_extra:
    line(f'Ceph    ! {ceph_extra}')
if mpath is not None:
    line(f'MPath   : {mpath}')
    if mpath_extra:
        line(f'MPath   ! {mpath_extra}')

section('USV / NUT')
for ups in ups_lines:
    line(f'USV     : {ups}')

section('DATASTORES / ZFS')
line(f'{"DATASTORES (USED)":<36}ZFS POOLS (USED)')
for i in range(max(len(storages), len(zpools), 1)):
    left = (f'{pad(storages[i][0], 21)} {storages[i][1]:>6}'
            if i < len(storages) else '')
    right = (f'{pad(zpools[i][0], 12)} {zpools[i][1]:<9} {zpools[i][2]:>5}'
             if i < len(zpools) else '')
    line(f'{left:<36}{right}'.rstrip())
if zfs_warning:
    line(f'ZFS WARNING: {zfs_warning}')

section('PHYSICAL DISKS - WEAR USED / YEARS ON')
line(f'{"DEVICE":<10} {"MODEL":<18} {"SERIAL":<27} {"WEAR":>5} {"YEARS":>5}')
for name, model, serial, wear, years in disk_rows:
    preview = serial if len(serial) <= 27 else serial[:26] + '~'
    line(f'{pad(name, 10)} {pad(model, 18)} {preview:<27} {wear:>5} {years:>5}')
    if len(serial) > 27:
        line(f'  Full serial {name}: {serial}')
if not disk_rows:
    line('(keine physischen Blockdevices erkannt)')


# ----------------------------------------------------------
# FORMATIERUNG: --mono ODER ANSI
# ----------------------------------------------------------

def wrap(value):
    return textwrap.wrap(
        value, width=WIDTH, subsequent_indent='   ',
        break_long_words=True, break_on_hyphens=False,
        replace_whitespace=False, drop_whitespace=False
    ) or ['']

if args.mono:
    output = ['=' * (WIDTH + 2)]
    for kind, value in rows:
        if kind == 'section':
            output.extend(['', value.upper(), '-' * (WIDTH + 2)])
        else:
            output.extend(wrap(value))
    output.append('=' * (WIDTH + 2))
else:
    RESET = '\x1b[0m'
    CYAN = '\x1b[1;36m'
    GREEN = '\x1b[1;32m'
    YELLOW = '\x1b[1;33m'
    RED = '\x1b[1;31m'
    # ANSI 47 = hellgrauer Hintergrund, 30 = schwarze Schrift
    GREY_BG_BLACK = '\x1b[47;30m'

    color_pattern = re.compile(
        r'HEALTH_WARN|HEALTH_ERR|HEALTH_OK|'
        r'REBOOT\?|DEGRADED|FAULTED|UNAVAIL|'
        r'ERROR|WARNING|OFFLINE|ONLINE|'
        r'BATTERIE|UNKNOWN|WARN|\bOK\b'
    )

    def colorize(value):
        def replace(match):
            word = match.group()
            if word in ('OK', 'ONLINE', 'HEALTH_OK'):
                color = GREEN
            elif word in ('HEALTH_WARN', 'REBOOT?', 'BATTERIE', 'WARN'):
                color = YELLOW
            else:
                color = RED
            return color + word + RESET
        return color_pattern.sub(replace, value)

    output = ['╔' + '═' * (WIDTH + 2) + '╗']
    for index, (kind, value) in enumerate(rows):
        if index == 1:
            output.append('╠' + '═' * (WIDTH + 2) + '╣')
        if kind == 'section':
            tag = f' {value} '
            output.append('╟' + CYAN + tag + RESET +
                          '─' * max(0, WIDTH + 2 - len(tag)) + '╢')
            continue
        for text in wrap(value):
            output.append('║ ' + colorize(text.ljust(WIDTH)) + ' ║')

    # Nur die unterste Statuszeile: hellgrau mit schwarzer Schrift.
    output.append('╠' + '═' * (WIDTH + 2) + '╣')
    footer = f' Stand: {stamp} | PVE {version} | {host}'
    output.append('║' + GREY_BG_BLACK +
                  pad(footer, WIDTH + 2) + RESET + '║')
    output.append('╚' + '═' * (WIDTH + 2) + '╝')

content = '\n'.join(output) + '\n'


# ----------------------------------------------------------
# BEIDE DATEIEN VORBEREITEN, DANACH ATOMAR ERSETZEN
# ----------------------------------------------------------

staged = []
try:
    for target in TARGETS:
        directory = os.path.dirname(target)
        fd, temp = tempfile.mkstemp(prefix='.proxmox-banner.', dir=directory)
        staged.append((temp, target))
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp, 0o644)
        os.chown(temp, 0, 0)

    for temp, target in staged:
        os.replace(temp, target)
finally:
    for temp, _ in staged:
        if os.path.exists(temp):
            os.unlink(temp)

PY
