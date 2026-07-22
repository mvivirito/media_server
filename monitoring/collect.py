#!/usr/bin/env python3
"""NAS host metrics collector -> node_exporter textfile.

Runs in a small privileged-ish sidecar next to node-exporter (see
stacks/monitoring.yml) and writes /textfile/nas.prom every INTERVAL seconds.
node_exporter picks it up via --collector.textfile.directory.

Sections (each independent; one failing never blanks the others):
  smart   - smartctl health/temp/wear per SATA disk (needs SYS_RAWIO + devices)
  cbc     - ADM Cloud Backup Center job history from its sqlite log DB (ro)
  images  - running containers' image age via the Docker socket (ro)
  dri     - ensures the i915 render node exists (udev misses it on some ADM
            builds; hardware transcoding needs it) and reports its presence
"""

import glob
import json
import os
import re
import socket
import sqlite3
import stat
import subprocess
import time

OUT_DIR = "/textfile"
OUT = os.path.join(OUT_DIR, "nas.prom")
CBC_DB = "/cbc/cloud_backup_center_log_datebase.db"
DOCKER_SOCK = "/var/run/docker.sock"
HOST_DRI = "/host-dri"
INTERVAL = int(os.environ.get("INTERVAL", "300"))


def smart_metrics():
    lines = []
    for dev in sorted(glob.glob("/dev/sd?")):
        disk = os.path.basename(dev)
        try:
            p = subprocess.run(["smartctl", "-H", "-A", "-i", dev],
                               capture_output=True, text=True, timeout=60)
            out = p.stdout
            model = (re.search(r"Device Model:\s+(.+)", out) or [None, "unknown"])[1].strip()
            healthy = 1 if re.search(r"self-assessment test result: PASSED", out) else 0
            lines.append(f'nas_smart_healthy{{disk="{disk}",model="{model}"}} {healthy}')
            for attr_id, name, metric in (
                ("194", "Temperature_Celsius", "nas_smart_temperature_celsius"),
                ("9", "Power_On_Hours", "nas_smart_power_on_hours"),
                ("5", "Reallocated_Sector_Ct", "nas_smart_reallocated_sectors"),
                ("197", "Current_Pending_Sector", "nas_smart_pending_sectors"),
            ):
                m = re.search(rf"^\s*{attr_id}\s+{name}.*?(\d+)(?:\s*\(.*\))?\s*$",
                              out, re.M)
                if m:
                    lines.append(f'{metric}{{disk="{disk}"}} {m.group(1)}')
            failing = len(re.findall(r"FAILING_NOW", out))
            lines.append(f'nas_smart_failing_attributes{{disk="{disk}"}} {failing}')
        except Exception:
            lines.append(f'nas_smart_healthy{{disk="{disk}",model="error"}} 0')
    return lines


def cbc_active_jobs():
    """Job names that still exist — deleted jobs stay in the log DB forever,
    but their task_configure file is removed, so metrics should stop too."""
    active = set()
    for path in glob.glob("/cbc/CBC_task_configure/*"):
        try:
            with open(path) as f:
                for line in f:
                    if line.startswith("task_name = "):
                        active.add(line.split(" = ", 1)[1].strip())
                        break
        except Exception:
            pass
    return active


def cbc_metrics():
    lines = []
    active = cbc_active_jobs()
    c = sqlite3.connect(f"file:{CBC_DB}?mode=ro", uri=True)
    rows = c.execute(
        "SELECT timestamp_of_log, status_of_log, name_of_log, event_of_log "
        "FROM cloud_backup_center_sql_database ORDER BY timestamp_of_log").fetchall()
    c.close()
    last_ok, last_err, running = {}, {}, {}
    for ts, status, name, _event in rows:
        m = re.search(r"Backup job (\S+)", name or "")
        if not m:
            continue
        job = m.group(1)
        if active and job not in active:
            continue
        if status == "SUCCESS" and "finished" in (name or ""):
            last_ok[job] = int(ts)
            running[job] = 0
        elif status == "BACKUPING":
            running[job] = 1
        elif status in ("ERROR", "FAIL", "FAILED"):
            last_err[job] = int(ts)
            running[job] = 0
    for job, ts in last_ok.items():
        lines.append(f'nas_cbc_job_last_success_timestamp{{job="{job}"}} {ts}')
    for job, ts in last_err.items():
        lines.append(f'nas_cbc_job_last_error_timestamp{{job="{job}"}} {ts}')
    for job, r in running.items():
        lines.append(f'nas_cbc_job_running{{job="{job}"}} {r}')
    return lines


def docker_api(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(20)
    s.connect(DOCKER_SOCK)
    s.sendall(f"GET {path} HTTP/1.0\r\nHost: docker\r\n\r\n".encode())
    buf = b""
    while chunk := s.recv(65536):
        buf += chunk
    s.close()
    return json.loads(buf.split(b"\r\n\r\n", 1)[1])


def image_metrics():
    lines = []
    containers = docker_api("/containers/json")
    for ct in containers:
        name = (ct.get("Names") or ["/?"])[0].lstrip("/")
        image = ct.get("Image", "?")
        img = docker_api(f"/images/{ct['ImageID']}/json")
        created = img.get("Created", "")
        # 2025-01-05T12:34:56.789Z -> epoch
        m = re.match(r"(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)", created)
        if m:
            ts = int(time.mktime(time.struct_time(
                (int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), int(m[6]), 0, 0, -1))))
            lines.append(
                f'nas_container_image_created_timestamp{{container="{name}",image="{image}"}} {ts}')
    return lines


def dri_metrics():
    node = os.path.join(HOST_DRI, "renderD128")
    if not os.path.exists(node):
        try:
            os.mknod(node, 0o666 | stat.S_IFCHR, os.makedev(226, 128))
        except Exception:
            pass
    present = 1 if os.path.exists(node) else 0
    return [f"nas_dri_render_node_present {present}"]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    while True:
        lines, errors = [], 0
        for section in (smart_metrics, cbc_metrics, image_metrics, dri_metrics):
            try:
                lines += section()
            except Exception:
                errors += 1
        lines.append(f"nas_metrics_collector_errors {errors}")
        lines.append(f"nas_metrics_collected_timestamp {int(time.time())}")
        tmp = OUT + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.rename(tmp, OUT)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
