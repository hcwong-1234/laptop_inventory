#!/usr/bin/env python3
"""
Linux inventory collector and uploader.

Tested on Ubuntu/Debian/AlmaLinux/Oracle Linux. Requires:
  - ssh client (for tunnel)
  - mysql client (CLI) in PATH

Behavior:
  - Collects hardware/OS/network data
  - Writes a local log under ./Inventory
  - Opens an SSH tunnel and inserts a row into dsg_it.asset_inv via mysql CLI
"""

import datetime
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional


# =========================
# CONFIGURATION
# =========================

SSH_HOST = "152.42.228.57"
SSH_USER = "root"
LOCAL_DB_PORT = 3307
REMOTE_DB_HOST = "127.0.0.1"
REMOTE_DB_PORT = 3306

MYSQL_USER = "romel"
MYSQL_PASS = os.environ.get("MYSQL_PASS", "ia5lnbvo8j")  # override via env for security
MYSQL_DB = "dsg_it"

SCRIPT_DIR = Path(__file__).resolve().parent
OUT_DIR = SCRIPT_DIR / "Inventory"
OUT_DIR.mkdir(parents=True, exist_ok=True)


# =========================
# HELPERS
# =========================

def require_command(name: str, install_hint: Optional[str] = None) -> None:
    if shutil.which(name):
        return
    print(f"[ERROR] Required command '{name}' not found in PATH.")
    if install_hint:
        print(f"        {install_hint}")
    sys.exit(1)


def run_cmd(cmd: List[str], timeout: int = 15) -> Optional[str]:
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=timeout)
        return out.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return None


def escape_sql(value: Optional[str]) -> str:
    if not value:
        return ""
    return value.replace("'", "''")


def is_port_open(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(1.0)
        try:
            sock.connect((host, port))
            return True
        except (ConnectionRefusedError, socket.timeout, OSError):
            return False


# =========================
# INVENTORY COLLECTION
# =========================

def read_file(path: str) -> Optional[str]:
    try:
        return Path(path).read_text().strip()
    except (FileNotFoundError, PermissionError):
        return None


def collect_hardware_profile() -> Dict[str, Optional[str]]:
    hw = {
        "serial_number": None,
        "manufacturer": None,
        "model": None,
        "cpu_name": None,
        "total_ram_bytes": None,
    }

    hw["serial_number"] = read_file("/sys/class/dmi/id/product_serial")
    hw["manufacturer"] = read_file("/sys/class/dmi/id/sys_vendor")
    hw["model"] = read_file("/sys/class/dmi/id/product_name")

    if not hw["cpu_name"]:
        cpuinfo = run_cmd(["lscpu"])
        if cpuinfo:
            for line in cpuinfo.splitlines():
                if line.lower().startswith("model name:"):
                    hw["cpu_name"] = line.split(":", 1)[1].strip()
                    break

    if not hw["cpu_name"]:
        cpuinfo_raw = read_file("/proc/cpuinfo")
        if cpuinfo_raw:
            for line in cpuinfo_raw.splitlines():
                if line.lower().startswith("model name"):
                    hw["cpu_name"] = line.split(":", 1)[1].strip()
                    break

    mem_kb = None
    meminfo = read_file("/proc/meminfo")
    if meminfo:
        for line in meminfo.splitlines():
            if line.startswith("MemTotal:"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    mem_kb = int(parts[1])
                break
    if mem_kb:
        hw["total_ram_bytes"] = mem_kb * 1024

    return hw


def collect_disks_info() -> str:
    # Prefer lsblk JSON if available, otherwise fall back to df -k
    lsblk_out = run_cmd(["lsblk", "-b", "-J", "-o", "NAME,SIZE,MOUNTPOINT"])
    if lsblk_out:
        return lsblk_out

    disks: List[Dict[str, object]] = []
    df_out = run_cmd(["df", "-k"])
    if df_out:
        for line in df_out.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 6:
                continue
            device = parts[0]
            try:
                size_bytes = int(parts[1]) * 1024
                free_bytes = int(parts[3]) * 1024
            except ValueError:
                continue
            mount_point = parts[-1]
            disks.append(
                {
                    "device": device,
                    "mount_point": mount_point,
                    "size_bytes": size_bytes,
                    "free_bytes": free_bytes,
                }
            )
    return json.dumps(disks, indent=2)


def collect_mac_addresses() -> str:
    macs: List[Dict[str, str]] = []
    ip_out = run_cmd(["ip", "-o", "link", "show"])
    if ip_out:
        for line in ip_out.splitlines():
            parts = line.split()
            if len(parts) >= 17:
                iface = parts[1].strip(":")
                mac = parts[17]
                macs.append({"interface": iface, "mac_address": mac})
            elif len(parts) >= 5 and parts[3] == "link/ether":
                iface = parts[1].strip(":")
                mac = parts[4]
                macs.append({"interface": iface, "mac_address": mac})
    return json.dumps(macs, indent=2)


def collect_systeminfo_raw() -> str:
    chunks: List[str] = []

    uname_out = run_cmd(["uname", "-a"])
    if uname_out:
        chunks.append("[uname -a]")
        chunks.append(uname_out)

    lsb_out = run_cmd(["lsb_release", "-a"])
    if lsb_out:
        chunks.append("[lsb_release -a]")
        chunks.append(lsb_out)

    lscpu_out = run_cmd(["lscpu"])
    if lscpu_out:
        chunks.append("[lscpu]")
        chunks.append(lscpu_out)

    free_out = run_cmd(["free", "-h"])
    if free_out:
        chunks.append("[free -h]")
        chunks.append(free_out)

    return "\n".join(chunks)


def collect_inventory() -> Dict[str, Optional[str]]:
    now = datetime.datetime.now()
    inventory_datetime = now.strftime("%Y-%m-%d %H:%M:%S")

    computer_name = run_cmd(["hostname"]) or socket.gethostname()
    logged_in_user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""

    os_name = "Linux"
    os_version = run_cmd(["cat", "/etc/os-release"])
    os_arch = run_cmd(["uname", "-m"]) or ""

    domain = run_cmd(["hostname", "--domain"]) or socket.getfqdn()

    hw = collect_hardware_profile()
    disks_info = collect_disks_info()
    mac_addresses = collect_mac_addresses()
    ip_config = run_cmd(["ip", "addr", "show"]) or ""
    systeminfo_raw = collect_systeminfo_raw()

    return {
        "inventory_datetime": inventory_datetime,
        "computer_name": computer_name,
        "logged_in_user": logged_in_user,
        "serial_number": hw.get("serial_number") or "",
        "manufacturer": hw.get("manufacturer") or "",
        "model": hw.get("model") or "",
        "os_name": os_name,
        "os_version": os_version or "",
        "os_arch": os_arch,
        "cpu_name": hw.get("cpu_name") or "",
        "total_ram_bytes": hw.get("total_ram_bytes"),
        "domain_or_workgroup": domain,
        "disks_info": disks_info,
        "mac_addresses": mac_addresses,
        "ip_config": ip_config,
        "systeminfo_raw": systeminfo_raw,
    }


# =========================
# SQL / DB
# =========================

def build_insert_sql(data: Dict[str, Optional[str]]) -> str:
    total_ram_val = data.get("total_ram_bytes")
    total_ram_sql = str(total_ram_val) if isinstance(total_ram_val, int) and total_ram_val > 0 else "NULL"

    tpl = """
INSERT INTO asset_inv (
    inventory_datetime,
    computer_name,
    logged_in_user,
    serial_number,
    manufacturer,
    model,
    os_name,
    os_version,
    os_arch,
    cpu_name,
    total_ram_bytes,
    domain_or_workgroup,
    disks_info,
    mac_addresses,
    ip_config,
    systeminfo_raw
) VALUES (
    '{inventory_datetime}',
    '{computer_name}',
    '{logged_in_user}',
    '{serial_number}',
    '{manufacturer}',
    '{model}',
    '{os_name}',
    '{os_version}',
    '{os_arch}',
    '{cpu_name}',
    {total_ram_bytes},
    '{domain_or_workgroup}',
    '{disks_info}',
    '{mac_addresses}',
    '{ip_config}',
    '{systeminfo_raw}'
);
""".strip()

    return tpl.format(
        inventory_datetime=escape_sql(data.get("inventory_datetime")),
        computer_name=escape_sql(data.get("computer_name")),
        logged_in_user=escape_sql(data.get("logged_in_user")),
        serial_number=escape_sql(data.get("serial_number")),
        manufacturer=escape_sql(data.get("manufacturer")),
        model=escape_sql(data.get("model")),
        os_name=escape_sql(data.get("os_name")),
        os_version=escape_sql(data.get("os_version")),
        os_arch=escape_sql(data.get("os_arch")),
        cpu_name=escape_sql(data.get("cpu_name")),
        total_ram_bytes=total_ram_sql,
        domain_or_workgroup=escape_sql(data.get("domain_or_workgroup")),
        disks_info=escape_sql(data.get("disks_info")),
        mac_addresses=escape_sql(data.get("mac_addresses")),
        ip_config=escape_sql(data.get("ip_config")),
        systeminfo_raw=escape_sql(data.get("systeminfo_raw")),
    )


def run_mysql_insert(insert_sql: str) -> int:
    mysql_cmd = [
        "mysql",
        "-u",
        MYSQL_USER,
        f"-p{MYSQL_PASS}",
        "-h",
        "127.0.0.1",
        "-P",
        str(LOCAL_DB_PORT),
        "-D",
        MYSQL_DB,
    ]

    result = subprocess.run(
        mysql_cmd,
        input=insert_sql.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    if result.stdout:
        print(result.stdout.decode("utf-8", errors="ignore").strip())
    if result.stderr:
        print(result.stderr.decode("utf-8", errors="ignore").strip())

    return result.returncode


# =========================
# SSH TUNNEL MANAGEMENT
# =========================

def open_ssh_tunnel() -> subprocess.Popen:
    cmd = [
        "ssh",
        "-o",
        "ExitOnForwardFailure=yes",
        "-N",
        "-L",
        f"{LOCAL_DB_PORT}:{REMOTE_DB_HOST}:{REMOTE_DB_PORT}",
        f"{SSH_USER}@{SSH_HOST}",
    ]

    print("Opening SSH tunnel... enter your SSH password if prompted.")
    proc = subprocess.Popen(cmd)

    deadline = time.time() + 90
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError("SSH process exited before tunnel was ready.")
        if is_port_open("127.0.0.1", LOCAL_DB_PORT):
            return proc
        time.sleep(1.0)

    proc.terminate()
    raise TimeoutError("Timed out waiting for SSH tunnel to open.")


def close_ssh_tunnel(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


# =========================
# MAIN FLOW
# =========================

def write_local_log(data: Dict[str, Optional[str]]) -> Path:
    out_file = OUT_DIR / f"{data.get('computer_name', 'linux')}_inventory.txt"
    lines = [
        "========================================",
        "  COMPANY LAPTOP INVENTORY SNAPSHOT",
        "========================================",
        f"Date/Time      : {data.get('inventory_datetime')}",
        f"Computer Name  : {data.get('computer_name')}",
        f"Logged-in User : {data.get('logged_in_user')}",
        f"Serial Number  : {data.get('serial_number')}",
        f"Manufacturer   : {data.get('manufacturer')}",
        f"Model          : {data.get('model')}",
        f"OS Name        : {data.get('os_name')}",
        f"OS Version     : {data.get('os_version')}",
        f"OS Arch        : {data.get('os_arch')}",
        f"CPU Name       : {data.get('cpu_name')}",
        f"Total RAM      : {data.get('total_ram_bytes')} bytes",
        f"Domain/Workgrp : {data.get('domain_or_workgroup')}",
        "",
        "[DISKS JSON]",
        data.get("disks_info", ""),
        "",
        "[MAC ADDRESSES JSON]",
        data.get("mac_addresses", ""),
        "",
        "[IP ADDR RAW]",
        data.get("ip_config", ""),
        "",
        "[SYSTEMINFO RAW]",
        data.get("systeminfo_raw", ""),
    ]
    out_file.write_text("\n".join(lines), encoding="utf-8")
    return out_file


def main() -> None:
    require_command("ssh", "Install OpenSSH client: sudo apt install openssh-client (or equivalent).")
    require_command(
        "mysql",
        "Install MySQL/MariaDB client: sudo apt install mysql-client (or dnf install mariadb).",
    )
    inventory = collect_inventory()
    log_path = write_local_log(inventory)
    print(f"Local log written to: {log_path}")

    insert_sql = build_insert_sql(inventory)
    sql_tmp = Path(tempfile.gettempdir()) / "inventory_insert_linux.sql"
    sql_tmp.write_text(insert_sql, encoding="utf-8")
    print(f"SQL preview written to: {sql_tmp}")

    tunnel_proc: Optional[subprocess.Popen] = None
    try:
        tunnel_proc = open_ssh_tunnel()
        print(f"SSH tunnel ready on localhost:{LOCAL_DB_PORT}")

        exit_code = run_mysql_insert(insert_sql)
        if exit_code == 0:
            print(f"[OK] Inventory row inserted into {MYSQL_DB}.asset_inv.")
        else:
            print(f"[ERROR] MySQL client exited with code {exit_code}.")
    except Exception as exc:
        print(f"[ERROR] {exc}")
    finally:
        if tunnel_proc:
            close_ssh_tunnel(tunnel_proc)


if __name__ == "__main__":
    main()
