#!/usr/bin/env bash
# Read-only system inventory for homelab / VPS disaster-recovery docs.
# Changes nothing on the host. Writes text files to ./inventory-<host>-<date>/
# Secrets are redacted on a best-effort basis: REVIEW THE OUTPUT before committing.
#
# Usage: sudo ./inventory.sh [output-dir]
set -u

HOST="$(hostname -s)"
OUT="${1:-./inventory-${HOST}-$(date +%Y%m%d)}"
mkdir -p "$OUT"
chmod 700 "$OUT"

# Redact values on lines that look like secrets (key=value, key: value, JSON, XML).
redact() {
  sed -E \
    -e 's/((pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|auth|credential|psk|salt|hash|cookie)[A-Za-z0-9_.-]*[[:space:]]*[=:][[:space:]]*).*/\1<REDACTED>/I' \
    -e 's#(<[A-Za-z0-9_]*(pass|secret|token|key|hash|salt)[A-Za-z0-9_]*>)[^<]+(</)#\1<REDACTED>\3#I' \
    -e 's#("[A-Za-z0-9_]*(pass|secret|token|key|auth)[A-Za-z0-9_]*"[[:space:]]*:[[:space:]]*")[^"]*#\1<REDACTED>#I' \
    -e 's#(://[^:/@[:space:]]+:)[^@/[:space:]]+@#\1<REDACTED>@#g'
}

# run <outfile> <cmd...>  -- capture command output, skip silently if missing
run() {
  local f="$OUT/$1"; shift
  command -v "$1" >/dev/null 2>&1 || return 0
  { echo "# \$ $*"; "$@" 2>&1; } | redact >> "$f"
  echo >> "$f"
}

# copy <outfile> <path...>  -- append redacted file contents
copy() {
  local f="$OUT/$1"; shift
  for p in "$@"; do
    [ -f "$p" ] || continue
    { echo "# ===== $p ====="; cat "$p"; echo; } 2>&1 | redact >> "$f"
  done
}

[ "$(id -u)" -eq 0 ] || echo "WARNING: not root; output will be incomplete." >&2

# ---- System -----------------------------------------------------------
run system.txt uname -a
copy system.txt /etc/os-release
run system.txt hostnamectl
run system.txt uptime
run system.txt lscpu
run system.txt free -h
run system.txt timedatectl
run system.txt dpkg -l 'linux-image*'
run system.txt systemd-detect-virt
run system.txt lsmod

# ---- Disks / storage --------------------------------------------------
run storage.txt lsblk -f -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS
run storage.txt df -hT
run storage.txt blkid
run storage.txt findmnt --real
copy storage.txt /etc/fstab /etc/crypttab /etc/mdadm/mdadm.conf /proc/mdstat
run storage.txt mdadm --detail --scan
run storage.txt pvs
run storage.txt vgs
run storage.txt lvs
run storage.txt zpool status
run storage.txt zfs list
run storage.txt btrfs filesystem show
# SMART summary (health only, not full dumps)
if command -v smartctl >/dev/null 2>&1; then
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    run storage.txt smartctl -i -H "/dev/$d"
  done
fi

# ---- Network ----------------------------------------------------------
run network.txt ip -br addr
run network.txt ip route
run network.txt ip -6 route
run network.txt resolvectl status
copy network.txt /etc/hosts /etc/resolv.conf /etc/hostname
for f in /etc/netplan/*.yaml /etc/network/interfaces /etc/systemd/network/*; do copy network.txt "$f"; done
run network.txt ss -tulpn
run network.txt nmcli connection show

# ---- Firewall / security ----------------------------------------------
run firewall.txt ufw status verbose
run firewall.txt iptables-save
run firewall.txt ip6tables-save
run firewall.txt nft list ruleset
run firewall.txt fail2ban-client status
for f in /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*; do copy firewall.txt "$f"; done
copy ssh.txt /etc/ssh/sshd_config
for f in /etc/ssh/sshd_config.d/*; do copy ssh.txt "$f"; done
# public key fingerprints only, never private keys
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -f "$f" ] && { echo "# $f"; ssh-keygen -lf "$f" 2>&1; } >> "$OUT/ssh.txt"
done

# ---- Users ------------------------------------------------------------
{ echo "# non-system users (uid>=1000) and groups"
  awk -F: '$3>=1000 && $3<65534 {print $1, $3, $6, $7}' /etc/passwd
  echo; getent group sudo docker 2>/dev/null; } > "$OUT/users.txt"
copy users.txt /etc/sudoers
for f in /etc/sudoers.d/*; do copy users.txt "$f"; done

# ---- Packages ---------------------------------------------------------
if command -v apt-mark >/dev/null 2>&1; then
  apt-mark showmanual | sort > "$OUT/apt-manual-packages.txt"
fi
run packages.txt dpkg --get-selections
run packages.txt snap list
run packages.txt flatpak list
run packages.txt pip3 list
run packages.txt npm ls -g --depth=0
copy apt-sources.txt /etc/apt/sources.list
for f in /etc/apt/sources.list.d/*; do copy apt-sources.txt "$f"; done
run apt-sources.txt apt-key list

# ---- Services / scheduling --------------------------------------------
run services.txt systemctl list-unit-files --state=enabled --no-pager
run services.txt systemctl list-units --type=service --state=running --no-pager
run services.txt systemctl list-timers --all --no-pager
# custom units
for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer /etc/systemd/system/*.mount; do copy custom-units.txt "$f"; done
copy cron.txt /etc/crontab
for f in /etc/cron.d/* /var/spool/cron/crontabs/*; do copy cron.txt "$f"; done
run cron.txt crontab -l

# ---- Docker -----------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  run docker.txt docker version
  run docker.txt docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Label "com.docker.compose.project.working_dir"}}'
  run docker.txt docker images
  run docker.txt docker network ls
  run docker.txt docker volume ls
  run docker.txt docker compose ls
  # Per-container run config WITHOUT env values (names only), mounts, restart policy
  mkdir -p "$OUT/docker-inspect"
  for c in $(docker ps -aq 2>/dev/null); do
    n="$(docker inspect -f '{{.Name}}' "$c" | tr -d /)"
    docker inspect "$c" 2>/dev/null | \
      python3 -c '
import json,sys
for o in json.load(sys.stdin):
    c=o.get("Config",{}); h=o.get("HostConfig",{})
    print(json.dumps({
      "name":o["Name"],"image":c.get("Image"),
      "env_var_names":[e.split("=",1)[0] for e in (c.get("Env") or [])],
      "cmd":c.get("Cmd"),"entrypoint":c.get("Entrypoint"),
      "labels":c.get("Labels"),"restart":h.get("RestartPolicy"),
      "ports":h.get("PortBindings"),"network_mode":h.get("NetworkMode"),
      "mounts":o.get("Mounts"),"devices":h.get("Devices"),
      "privileged":h.get("Privileged"),"cap_add":h.get("CapAdd")},indent=2))' \
      > "$OUT/docker-inspect/$n.json" 2>/dev/null
  done
  # Compose files (redacted) -- found via running containers' labels, plus common spots
  dirs="$(docker ps -aq 2>/dev/null | xargs -r docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null | sort -u)"
  dirs="$dirs $(ls -d /opt/* /srv/* /home/*/docker* /home/*/compose* 2>/dev/null)"
  mkdir -p "$OUT/compose"
  for d in $dirs; do
    [ -d "$d" ] || continue
    for f in "$d"/docker-compose*.y*ml "$d"/compose*.y*ml; do
      [ -f "$f" ] || continue
      dest="$OUT/compose/$(echo "$f" | tr / _)"
      { echo "# source: $f"; redact < "$f"; } > "$dest"
    done
    # list .env files by name and variable names only
    for e in "$d"/.env "$d"/*.env; do
      [ -f "$e" ] && { echo "# $e (names only)"; cut -d= -f1 "$e" | grep -v '^#' ; } >> "$OUT/env-var-names.txt"
    done
  done
fi

# ---- Web / reverse proxy / apps ---------------------------------------
for f in /etc/nginx/nginx.conf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/* \
         /etc/caddy/Caddyfile /etc/apache2/sites-enabled/*; do copy webserver.txt "$f"; done
run webserver.txt certbot certificates
run webserver.txt ls -la /etc/letsencrypt/live

# ---- Shares / VPN / misc ----------------------------------------------
copy shares.txt /etc/samba/smb.conf /etc/exports
run vpn.txt wg show interfaces
run vpn.txt tailscale status
for f in /etc/wireguard/*.conf; do copy vpn.txt "$f"; done   # PrivateKey lines are redacted
copy misc.txt /etc/logrotate.conf /etc/rsyslog.conf /etc/unattended-upgrades/*.conf
run misc.txt rclone listremotes
run misc.txt restic version
run misc.txt borg --version

# ---- OpenMediaVault ---------------------------------------------------
if [ -d /etc/openmediavault ]; then
  mkdir -p "$OUT/omv"
  run omv/info.txt omv-sysinfo
  run omv/info.txt dpkg -l 'openmediavault*'
  # Full config database, redacted. This is the single most useful OMV restore artifact.
  [ -f /etc/openmediavault/config.xml ] && redact < /etc/openmediavault/config.xml > "$OUT/omv/config.xml.redacted"
  run omv/shares.txt omv-confdbadm read conf.system.sharedfolder
  run omv/fs.txt omv-confdbadm read conf.system.filesystem.mountpoint
  run omv/services.txt omv-confdbadm read conf.service.smb
  run omv/services.txt omv-confdbadm read conf.service.nfs
  run omv/services.txt omv-confdbadm read conf.service.ssh
  run omv/plugins.txt dpkg -l '*omv-extras*' 'openmediavault-*'
fi

# ---- VPS-specific hints -----------------------------------------------
{ echo "# public IP (outbound lookup)"; curl -fsS --max-time 5 https://ifconfig.me 2>&1; echo; } >> "$OUT/network.txt" || true

# ---- Final pass: scrub anything that still smells like a secret --------
echo "Scanning for leftovers..."
grep -rIlE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|xox[abp]-' "$OUT" \
  && echo "!! Possible secrets found in files listed above. Remove them before committing." \
  || echo "No obvious private keys/tokens found (still review manually)."

echo "Done: $OUT"
echo "Review it, then tar and send or commit under hosts/${HOST}/"
