#!/usr/bin/env bash
# Proxmox VE Login Banner - Norton Commander Style
# Default: ANSI blue /etc/issue + /etc/motd
# Options: --mono --no-issue --no-motd
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

parser = argparse.ArgumentParser(description='Proxmox VE Norton Commander Login Banner')
parser.add_argument('--mono', action='store_true', help='ASCII ohne Farbe')
parser.add_argument('--no-issue', action='store_true', help='/etc/issue nicht aktualisieren')
parser.add_argument('--no-motd', action='store_true', help='/etc/motd nicht aktualisieren')
args = parser.parse_args()
if args.no_issue and args.no_motd:
    parser.error('Beide Ausgabeziele wurden deaktiviert')
TARGETS = ([] if args.no_issue else ['/etc/issue']) + ([] if args.no_motd else ['/etc/motd'])
WIDTH = 76
RESET = '\033[0m'
COLORS = {
    'normal': '\033[44;97m',
    'white': '\033[1;44;97m',
    'yellow': '\033[1;44;93m',
    'cyan': '\033[1;44;96m',
    'green': '\033[1;44;92m',
    'red': '\033[1;44;91m',
    'orange': '\033[1;38;5;208;44m',
}

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
    return 'green' if text.upper() in ('OK', 'ONLINE', 'HEALTH_OK', 'ACTIVE', 'UP') else 'red'

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
free_pct = mfree * 100 / mtotal if mtotal else None
mem_text = (f'{mfree/1048576:.1f} / {mtotal/1048576:.1f} GiB frei '
            f'({free_pct:.1f}%)') if free_pct is not None else 'UNKNOWN'
mem_color = ('green' if free_pct >= 20 else 'yellow' if free_pct >= 10 else 'red') if free_pct is not None else 'yellow'

# Load is normalized load average, not measured CPU utilization.
cores = os.cpu_count() or 1
try:
    la = os.getloadavg()
    load_pct = [n / cores * 100 for n in la]
    load_text = '  '.join(f'{label}: {n:.0f}%' for label, n in zip(('1m', '5m', '15m'), load_pct))
    load_color = 'red' if max(load_pct) >= 100 else 'yellow' if max(load_pct) >= 75 else 'green'
except OSError:
    load_text, load_color = 'UNKNOWN', 'yellow'

# IP addresses; Linux bridges with host-facing LAN count as physical.
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
if isinstance(ip_data, list):
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
                (physical_ips if is_physical_ip(name) else virtual_ips).append(entry)
physical_ips = list(dict.fromkeys(physical_ips))
virtual_ips = list(dict.fromkeys(virtual_ips))

# Physical NICs
nics = []
try:
    interfaces = sorted(os.listdir('/sys/class/net'))
except OSError:
    interfaces = []
for name in interfaces:
    base = f'/sys/class/net/{name}'
    if not os.path.exists(f'{base}/device'):
        continue
    carrier, speed, duplex = None, '?', '?'
    for key in ('carrier', 'speed', 'duplex'):
        try:
            with open(f'{base}/{key}') as f:
                value = f.read().strip()
            if key == 'carrier':
                carrier = value
            elif key == 'speed':
                mb = int(value)
                if 0 < mb < 1000000:
                    speed = f'{mb/1000:g}G' if mb >= 1000 else f'{mb}M'
            else:
                duplex = value.upper()
        except (OSError, ValueError):
            pass
    if carrier is None or speed == '?':
        _, eth = run(['ethtool', name], timeout=3)
        if 'Link detected: yes' in eth:
            carrier = '1'
        elif 'Link detected: no' in eth:
            carrier = '0'
        m = re.search(r'Speed:\s*(\d+)Mb/s', eth)
        if m:
            mb = int(m.group(1))
            speed = f'{mb/1000:g}G' if mb >= 1000 else f'{mb}M'
        m = re.search(r'Duplex:\s*(\w+)', eth)
        if m:
            duplex = m.group(1).upper()
    if carrier == '1':
        nics.append((f'{name}[UP {speed}/{duplex}]', 'green'))
    elif carrier == '0':
        nics.append((f'{name}[DOWN]', 'red'))
    else:
        nics.append((f'{name}[UNKNOWN]', 'yellow'))

# Guests, stopped = orange
# Each guest name is colored, without an explicit status suffix.
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
        status = (fields[1] if container else fields[2]).lower()
        color = 'green' if status == 'running' else 'orange' if status == 'stopped' else 'red'
        result.append((f'{fields[0]}:{name}', color))
    return result
vms = get_guests(['qm', 'list'])
lxcs = get_guests(['pct', 'list'], container=True)

# Storage: show actual AVAILABLE GiB and available percentage.
# pvesm status columns: Name Type Status Total Used Available %
storages = []
rc, storage_output = run(['pvesm', 'status'], timeout=12)
if rc == 0:
    for line in storage_output.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 3:
            continue
        if fields[2] != 'active' or len(fields) < 7:
            storages.append((fields[0], '-', 'OFF', 'red'))
            continue
        available_kib = number(fields[5])
        total_kib = number(fields[3])
        used_pct = number(fields[6])
        if total_kib and available_kib is not None:
            pct = 100 * available_kib / total_kib
        elif used_pct is not None:
            pct = 100 - used_pct
        else:
            pct = None
        free_gib = f'{available_kib/1048576:.1f}' if available_kib is not None else '?'
        free_pc = f'{pct:.0f}%' if pct is not None else '?'
        color = 'red' if pct is not None and pct < 10 else 'yellow' if pct is not None and pct < 20 else 'green'
        storages.append((fields[0], free_gib, free_pc, color))

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
        color = 'red' if health != 'ONLINE' or (usage is not None and usage > 80) else 'green'
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

# Ceph
ceph, ceph_details = 'nicht konfiguriert', ''
if os.path.exists('/etc/pve/ceph.conf') or os.path.exists('/etc/ceph/ceph.conf'):
    data = read_json(['ceph', 'status', '--format', 'json'], timeout=10)
    if not data:
        ceph = 'ERROR: Ceph nicht erreichbar'
    else:
        hd = data.get('health') or {}
        health = hd.get('status', 'UNKNOWN')
        osd = (data.get('osdmap') or {}).get('osdmap') or {}
        ceph = (f"{health} | OSD: {osd.get('num_up_osds','?')}/{osd.get('num_osds','?')} | "
                f"IN: {osd.get('num_in_osds','?')} | MON: {len(data.get('quorum_names') or [])}")
        if health != 'HEALTH_OK':
            ceph_details = ', '.join(list((hd.get('checks') or {}).keys())[:3])

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
    return ' | '.join(parts), color

if shutil.which('upsc'):
    targets = nut_targets()
    ups_lines = [read_ups(target) for target in targets[:10]] if targets else [('Keine USV gefunden', 'yellow')]
else:
    ups_lines = [('NUT nicht installiert', 'yellow')]

# SMART / wearout / lifetime estimation
# Lifetime estimate assumes the same wear-per-power-on-hour rate continues.
# It estimates remaining *write endurance*, NOT hardware failure time.
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
                elif aid == 231 and any(t in name for t in ('life_left', 'lifetime_remain', 'ssd_life')):
                    if norm is not None and 0 <= norm <= 100:
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
    health, color = smart_health(smart, wear)
    disks.append((name, model, serial, wear_text, years, remain, health, color))

# Render input as colored text segments.
ROWS = []
def row(*parts):
    ROWS.append(('row', [part if isinstance(part, tuple) else seg(part) for part in parts]))
def section(title):
    ROWS.append(('section', clean(title)))
def guests_row(label, guests):
    parts = [seg(f'{label:<8}: ')]
    for i, (name, color) in enumerate(guests):
        if i:
            parts.append(seg(', '))
        parts.append(seg(name, color))
    if not guests:
        parts.append(seg('-'))
    row(*parts)

row(seg(f'PROXMOX VE {version}', 'yellow'), seg(f' | {host}', 'white'))
row('IP phys : ', seg(', '.join(physical_ips) or '-', 'cyan'))
row('IP virt : ', seg(', '.join(virtual_ips) or '-', 'cyan'))
row('Kernel  : ', seg(kernel, 'white'), ' [', seg(kernel_status, 'green' if kernel_status == 'OK' else 'yellow' if kernel_status == 'UNKNOWN' else 'red'), ']')
row(f'Uptime  : {uptime} | Update: {now}')
row('Memory  : ', seg(mem_text, mem_color))
row('CPUs    : ', seg(f'{cores} logische Kerne', 'white'))
row('Load    : ', seg(load_text, load_color))

section('PHYSICAL NETWORK INTERFACES')
parts = [seg('NICs    : ')]
for i, (label, color) in enumerate(nics):
    if i:
        parts.append(seg(', '))
    parts.append(seg(label, color))
row(*parts) if nics else row('NICs    : -')

section('VIRTUAL MACHINES / CONTAINERS')
guests_row('VMs', vms)
guests_row('LXCs', lxcs)
section('CLUSTER / CEPH / MULTIPATH')
row('Cluster : ', seg(cluster, 'red' if 'ERROR' in cluster else 'green' if 'Quorum: OK' in cluster else 'white'))
row('Ceph    : ', seg(ceph, 'green' if 'HEALTH_OK' in ceph else 'yellow' if 'HEALTH_WARN' in ceph else 'red' if 'ERROR' in ceph or 'HEALTH_ERR' in ceph else 'white'))
if ceph_details:
    row('Ceph    : ', seg(ceph_details, 'red'))
if multipath is not None:
    row('MPath   : ', seg(multipath, 'red' if 'ERROR' in multipath else 'green'))
    if multipath_details:
        row('MPath   : ', seg(multipath_details, 'red'))

section('UPS / NUT')
for text, color in ups_lines:
    row('UPS     : ', seg(text, color))

section('DATASTORES / ZFS POOLS')
row(seg(f"{'DATASTORES (FREE)':<37}", 'cyan'), seg('ZFS POOLS (USED)', 'cyan'))
row(seg(f"{'NAME':<18} {'GiB':>8} {'FREE%':>6}    ", 'cyan'), seg(f"{'POOL':<13} {'STATE':<9} {'USED%':>5}", 'cyan'))
for i in range(max(len(storages), len(zpools), 1)):
    parts = []
    if i < len(storages):
        name, free_gib, free_pc, color = storages[i]
        parts.extend((seg(f'{pad(name,18)} '), seg(f'{free_gib:>8} {free_pc:>6}', color), seg('    ')))
    else:
        parts.append(seg(' ' * 37))
    if i < len(zpools):
        name, health, used, color = zpools[i]
        parts.append(seg(pad(name, 13) + ' '))
        parts.append(seg(f'{health:<9} {used:>5}', color))
    row(*parts)
for item in zfs_jobs:
    row('ZFS JOB : ', seg(item, 'red'))
for item in zfs_warnings:
    row('ZFS WARN: ', seg(item, 'red'))

section('PHYSICAL DISKS / SMART / ENDURANCE EST.')
row(seg(f"{'DEVICE':<8} {'MODEL':<15} {'SERIAL':<17} {'WEAR':>5} {'ON-Y':>5} {'LEFT-Y':>6} {'SMART':>7}", 'cyan'))
for name, model, serial, wear, years, remain, health, color in disks:
    row(seg(pad(name, 8), color),
        seg(f' {pad(model,15)} {pad(serial,17)} {wear:>5} {years:>5} {remain:>6} '),
        seg(f'{health:>7}', color))
    if len(serial) > 17:
        row(f'  Full serial {name}: {serial}')
if not disks:
    row(seg('Keine physischen Datentraeger erkannt', 'yellow'))
row(seg('LEFT-Y = Wearout-Hochrechnung (keine Ausfallprognose)', 'yellow'))
ROWS.append(('footer', f' {host} | Proxmox VE {version} | {now} '))

# Split segments by visible characters, leaving color groups intact.
def wrap_segments(parts):
    lines, current, length = [], [], 0
    for text, color in parts:
        while text:
            space = WIDTH - length
            if space == 0:
                lines.append(current)
                current, length = [], 0
                space = WIDTH
            if len(text) <= space:
                current.append((text, color))
                length += len(text)
                break
            if length and len(text) <= WIDTH:
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
    def border(left, middle, right):
        output.append(yellow + left + middle * (WIDTH + 2) + right + RESET)
    def content(parts):
        for wrapped in wrap_segments(parts):
            visible = sum(len(text) for text, _ in wrapped)
            line = yellow + '║' + white + ' '
            for text, color in wrapped:
                line += COLORS.get(color, white) + text
            output.append(line + white + ' ' * (WIDTH - visible + 1) + yellow + '║' + RESET)
    border('╔', '═', '╗')
    for index, (kind, value) in enumerate(ROWS):
        if index == 1:
            border('╠', '═', '╣')
        if kind == 'section':
            title = f' {value} '[:WIDTH + 2]
            output.append(yellow + '╟' + '─' + cyan + title + yellow + '─' * max(0, WIDTH + 1 - len(title)) + '╢' + RESET)
        elif kind == 'row':
            content(value)
        elif kind == 'footer':
            border('╠', '═', '╣')
            content([seg(value, 'yellow')])
    border('╚', '═', '╝')
    return '\n'.join(output) + '\n'

def render_mono():
    output = ['=' * (WIDTH + 4)]
    for kind, value in ROWS:
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
