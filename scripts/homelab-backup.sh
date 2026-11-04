#!/usr/bin/env bash
#
# homelab-backup.sh - full-node backup for JARVIS (Docker home lab)
#
# What it does
#   1. Stops the containers whose data is a live database (Plex, Nextcloud,
#      Uptime Kuma, Signal API, Portainer) so their files are consistent.
#   2. Copies service data + host settings to a staging area on the SSD
#      (fast), then restarts the containers. Downtime = the copy time only.
#   3. Pi-hole is never stopped: its SQLite databases are copied with SQLite's
#      online-backup API and integrity-checked.
#   4. Compresses staging into ONE archive on the 6TB drive, verifies it,
#      asserts every required path is inside, writes a SHA-256, rotates old ones.
#   5. Reports success/failure to an Uptime Kuma push monitor (optional).
#
# Run as root (root's crontab). Needs: rsync sqlite3 docker curl flock
#
# RESTORE (new machine, 6TB mounted at /mnt/6TB_Storage):
#   sudo mkdir /tmp/restore
#   sudo tar -xzpf <archive> -C /tmp/restore --numeric-owner
#   sudo rsync -aH --numeric-ids /tmp/restore/data/ /
#   (host/ and inventory/ are reference material - review before applying)

set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------------------- configuration ----------------------------
BACKUP_ROOT="/mnt/6TB_Storage/jarvis_node_backups"
MOUNT_POINT="/mnt/6TB_Storage"
STAGE_BASE="/var/backups/homelab-stage"      # on the SSD, not the 6TB drive
KEEP=14                                      # how many archives to keep
MIN_FREE_GB=20                               # required free space on 6TB
MIN_FREE_STAGE_GB=10                         # required free space on SSD
KUMA_PUSH_FILE="/root/.kuma_push_url"        # optional: one line, Kuma push URL

# Containers stopped during the copy (their data is a live database).
# Order matters for ALERTING: Uptime Kuma is stopped FIRST (so it cannot raise
# false alarms while the others are down) and started LAST, after signal-api
# has had time to come back (so Kuma can always deliver Signal alerts).
STOP_LIST=(uptime-kuma plex nextcloud signal-api portainer)
START_LIST=(signal-api portainer plex nextcloud uptime-kuma)
KUMA_START_DELAY=30                          # seconds to let the others come up first

# Service data copied while its container is stopped
COLD_PATHS=(
  /opt/plex/config
  /opt/nextcloud/config
  /mnt/6TB_Storage/nextcloud_data
  /home/admin/uptime-kuma_data
  /home/admin/signal-api
  /var/lib/docker/volumes/portainer_data
)

# Service data that is safe to copy live (small, plain files)
HOT_PATHS=(
  /home/admin/homepage_config
  /home/admin/wg_easy
  /home/admin/duckdns
  /home/admin/unbound_config
)

# Host settings kept for reference when rebuilding (skipped if absent)
HOST_PATHS=(
  /etc/ufw /etc/fstab /etc/hosts /etc/netplan /etc/samba/smb.conf
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/docker/daemon.json
  /etc/cron.d /var/spool/cron/crontabs /etc/systemd/system
  /usr/local/bin /usr/local/sbin    # all custom scripts (whole folders, so new ones are included automatically)
  /etc/default/grub /etc/UPower/UPower.conf
  /var/lib/jarvis-netstats          # long-term DNS/ad-blocking/DHCP statistics (jarvis-netstats)
)

# Rebuildable clutter we do not need to keep
EXCLUDES=(
  --exclude='Plex Media Server/Cache'
  --exclude='Plex Media Server/Logs'
  --exclude='Plex Media Server/Crash Reports'
)

# ------------------------------- state ---------------------------------
STAMP="$(date +%Y%m%d_%H%M%S)"
WORK="$STAGE_BASE/$STAMP"
STAGE="$WORK/stage"
ARCHIVE="$BACKUP_ROOT/jarvis_full_$STAMP.tar.gz"
NICE=(nice -n 19 ionice -c3)                 # be gentle on the old hardware
STOPPED=()
RESTART_FAILED=0

# ----------------------------- functions -------------------------------
log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERROR: $*"; exit 1; }

notify() {   # notify up|down "message"  -> Uptime Kuma push monitor
  [[ -r "$KUMA_PUSH_FILE" ]] || return 0
  local url
  url="$(head -n1 "$KUMA_PUSH_FILE")"
  url="${url%%\?*}"
  curl -fsS -m 15 --retry 12 --retry-delay 5 --retry-connrefused \
       --get --data-urlencode "status=$1" --data-urlencode "msg=$2" \
       "$url" >/dev/null \
    || log "WARN: could not reach the Uptime Kuma push URL"
}

restart_containers() {
  local c any_started=0
  for c in "${START_LIST[@]}"; do
    [[ " ${STOPPED[*]:-} " == *" $c "* ]] || continue     # only what we stopped
    if [[ $c == uptime-kuma && $any_started -eq 1 ]]; then
      log "waiting ${KUMA_START_DELAY}s so signal-api and the others are up before Kuma"
      sleep "$KUMA_START_DELAY"
    fi
    if docker start "$c" >/dev/null; then
      log "started $c"; any_started=1
    else
      log "WARN: failed to start $c"
      RESTART_FAILED=1
    fi
  done
  STOPPED=()
}

on_exit() {
  local rc=$?
  trap - EXIT ERR
  restart_containers                  # always bring services back
  if (( rc == 0 && RESTART_FAILED )); then rc=1; fi
  rm -rf "$WORK"                      # staging holds secrets: never leave it
  if (( rc == 0 )); then
    log "SUCCESS: $ARCHIVE"
    notify up "OK $(basename "$ARCHIVE")"
  else
    rm -f "$ARCHIVE.partial"
    log "FAILED (exit $rc)"
    notify down "backup failed (exit $rc)"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'log "command failed at line $LINENO"' ERR

copy() {     # copy <subdir> [rsync-options] <absolute paths...>
  local dest="$STAGE/$1" rc=0
  shift
  "${NICE[@]}" rsync -aHR --numeric-ids "${EXCLUDES[@]}" "$@" "$dest/" || rc=$?
  # exit 24 = a file vanished mid-copy (harmless for logs); anything else is fatal
  (( rc == 0 || rc == 24 )) || die "rsync failed (exit $rc) for: $*"
}

# ------------------------------ preflight ------------------------------
log "=== backup $STAMP starting ==="
(( EUID == 0 )) || die "must run as root"

exec 9>/var/lock/homelab-backup.lock
flock -n 9 || die "another backup is already running"

for t in rsync sqlite3 docker curl flock; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done

mountpoint -q "$MOUNT_POINT" \
  || die "$MOUNT_POINT is not mounted (refusing to write to the boot disk)"

case "$(findmnt -no FSTYPE "$MOUNT_POINT")" in
  ext4|ext3|xfs|btrfs) ;;
  *) die "unsupported filesystem on $MOUNT_POINT (ownership would not be preserved)" ;;
esac

install -d -m 700 -o root -g root "$BACKUP_ROOT" "$STAGE_BASE"

free_gb=$(df --output=avail -BG "$BACKUP_ROOT" | tail -1 | tr -dc '0-9')
(( free_gb >= MIN_FREE_GB )) || die "only ${free_gb}G free on the backup drive"
free_stage_gb=$(df --output=avail -BG "$STAGE_BASE" | tail -1 | tr -dc '0-9')
(( free_stage_gb >= MIN_FREE_STAGE_GB )) || die "only ${free_stage_gb}G free for staging"

for p in "${COLD_PATHS[@]}" "${HOT_PATHS[@]}" /etc/pihole; do
  [[ -e "$p" ]] || die "required path missing: $p"
done

mkdir -p "$STAGE/data" "$STAGE/host" "$STAGE/inventory"

# --------------------- stage 1: consistent copy (brief downtime) ---------------------
for c in "${STOP_LIST[@]}"; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" == "true" ]]; then
    log "stopping $c"
    STOPPED+=("$c")
    docker stop -t 60 "$c" >/dev/null
  fi
done

log "copying service data (containers stopped)"
copy data "${COLD_PATHS[@]}"
restart_containers                    # downtime ends here

# --------------------- stage 2: things that need no downtime ---------------------
log "copying service data (live-safe)"
copy data "${HOT_PATHS[@]}"

log "copying Pi-hole (no downtime, SQLite online backup)"
copy data --exclude='gravity.db*' --exclude='pihole-FTL.db*' /etc/pihole
for db in gravity.db pihole-FTL.db; do
  src="/etc/pihole/$db"
  dst="$STAGE/data/etc/pihole/$db"
  [[ -f "$src" ]] || die "Pi-hole database not found: $src"
  sqlite3 "$src" ".timeout 30000" ".backup '$dst'"
  [[ "$(sqlite3 "$dst" 'PRAGMA integrity_check;')" == "ok" ]] \
    || die "integrity check failed for $db"
  chown --reference="$src" "$dst"
  chmod --reference="$src" "$dst"
done

log "copying host settings (reference for rebuilds)"
for p in "${HOST_PATHS[@]}"; do
  if [[ -e "$p" ]]; then copy host "$p"; else log "note: $p not present, skipped"; fi
done

log "writing system inventory"
INV="$STAGE/inventory"
{
  echo "host: $(hostname)   backup: $STAMP   kernel: $(uname -r)"
  lsb_release -ds 2>/dev/null || true
} > "$INV/summary.txt"
lsblk -f                                   > "$INV/lsblk.txt"
findmnt --real                             > "$INV/mounts.txt"
ip -br address                             > "$INV/network.txt"
id admin                                > "$INV/user-admin-id.txt" 2>&1 || true
dpkg --get-selections                      > "$INV/packages.txt"
systemctl list-unit-files --state=enabled  > "$INV/enabled-services.txt"
ufw status numbered                        > "$INV/ufw.txt" 2>&1 || true
iptables-save                              > "$INV/iptables.txt" 2>&1 || true
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' > "$INV/containers.txt"
docker network ls                          > "$INV/docker-networks.txt"
docker volume ls                           > "$INV/docker-volumes.txt"
crontab -l                                 > "$INV/crontab-root.txt" 2>&1 || true
crontab -l -u admin                     > "$INV/crontab-admin.txt" 2>&1 || true
# Video library is NOT backed up (accepted risk, re-acquirable); keep a list of what is there.
find /mnt/6TB_Storage/Video -type f -printf '%P\t%s\n' 2>/dev/null | sort > "$INV/video-library.txt" || true

# --------------------- stage 3: archive, verify, rotate ---------------------
log "compressing archive"
"${NICE[@]}" tar --numeric-owner -C "$STAGE" -czf "$ARCHIVE.partial" .

log "verifying archive"
gzip -t "$ARCHIVE.partial"
tar -tzf "$ARCHIVE.partial" > "$WORK/listing.txt"
for p in "${COLD_PATHS[@]}" "${HOT_PATHS[@]}" /etc/pihole; do
  grep -qF "./data$p/" "$WORK/listing.txt" \
    || die "coverage check failed: $p is not in the archive"
done
grep -qF "./data/etc/pihole/gravity.db" "$WORK/listing.txt" \
  || die "coverage check failed: Pi-hole gravity.db missing"

mv "$ARCHIVE.partial" "$ARCHIVE"      # only complete, verified archives get the real name
( cd "$BACKUP_ROOT" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
log "archive size: $(du -h "$ARCHIVE" | cut -f1)"

# Count-based retention: only SUCCESSFUL runs create archives, so a streak of
# failures can never rotate your last good backups away.
mapfile -t OLD < <(ls -1t "$BACKUP_ROOT"/jarvis_full_*.tar.gz | tail -n +"$((KEEP + 1))")
for f in "${OLD[@]}"; do
  log "retention: removing $(basename "$f")"
  rm -f -- "$f" "$f.sha256"
done
