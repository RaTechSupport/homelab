#!/usr/bin/env bash
# backup-mirror.sh - root cron after the nightly backup: copy the newest archive to the SSD and stage an encrypted copy for off-site.
#
#   sudo backup-mirror.sh    mirror the newest archive now (skips steps already done)
#
# 1. SSD copy of the newest archive on the 6TB drive -> /var/backups/jarvis_node_backups (keep 14).
#    The copy is checked against the archive's .sha256, so a damaged source or copy is never kept.
# 2. age-encrypted copy -> outbox /var/backups/jarvis_outbox/files (keep 2), readable only by the
#    'backuppull' SFTP account; the owner's PC pulls it into Google Drive (scripts/windows/).
#    Only the PUBLIC key is on JARVIS (/etc/jarvis/backup-age.pub, also in the repo); the private
#    key is in the owner's password manager. Restore: age -d -i key.txt X.tar.gz.age > X.tar.gz
# Shares /var/lock/homelab-backup.lock with homelab-backup.sh and update-ub: waits until they finish.
# Log: /var/log/jarvis_backup_mirror.log. Root cron: 30 7 * * * (07:30 UTC, 30 min after the backup).
set -Eeuo pipefail
umask 077

SRC=/mnt/6TB_Storage/jarvis_node_backups
SSD=/var/backups/jarvis_node_backups
OUTBOX=/var/backups/jarvis_outbox/files
PUBKEY=/etc/jarvis/backup-age.pub
PULL_GROUP=backuppull
KEEP_SSD=14
KEEP_OUT=2
LOG=/var/log/jarvis_backup_mirror.log

log() { echo "[$(date -u '+%F %T')] $*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "ERROR: command failed at line $LINENO"' ERR

(( EUID == 0 )) || die "must run as root"
exec 9>/var/lock/homelab-backup.lock
flock -w 7200 9 || die "backup lock still busy after 2 h"

command -v age >/dev/null || die "age is not installed"
[[ -r $PUBKEY ]] || die "public key missing: $PUBKEY"
mountpoint -q /mnt/6TB_Storage || die "/mnt/6TB_Storage is not mounted"
getent group "$PULL_GROUP" >/dev/null || die "group $PULL_GROUP missing"

newest=$(find "$SRC" -maxdepth 1 -name 'jarvis_full_*.tar.gz' -printf '%T@ %p\n' | sort -rn | head -n1 | cut -d' ' -f2-)
[[ -n $newest ]] || die "no archive in $SRC"
name=${newest##*/}
[[ -s $newest.sha256 ]] || die "checksum file missing: $name.sha256"
log "=== mirror $name ==="

# --- 1. SSD copy (keep 14) ---
mkdir -p "$SSD"
if [[ -f $SSD/$name ]] && ( cd "$SSD" && sha256sum --quiet -c "$name.sha256" ); then
  log "SSD: $name already present and verified"
else
  nice -n 19 ionice -c3 cp -- "$newest" "$SSD/$name.partial"
  cp -- "$newest.sha256" "$SSD/$name.sha256"
  mv -- "$SSD/$name.partial" "$SSD/$name"
  ( cd "$SSD" && sha256sum --quiet -c "$name.sha256" ) || { rm -f -- "$SSD/$name" "$SSD/$name.sha256"; die "SSD copy failed the checksum (source or copy damaged)"; }
  log "SSD: copied and verified $name ($(du -h "$SSD/$name" | cut -f1))"
fi
mapfile -t old < <(find "$SSD" -maxdepth 1 -name 'jarvis_full_*.tar.gz' -printf '%T@ %p\n' | sort -rn | tail -n +"$((KEEP_SSD + 1))" | cut -d' ' -f2-)
for f in "${old[@]}"; do log "SSD retention: removing ${f##*/}"; rm -f -- "$f" "$f.sha256"; done

# --- 2. encrypted copy for off-site (outbox, keep 2) ---
enc="$OUTBOX/$name.age"
if [[ -f $enc && -s $enc.sha256 ]]; then
  log "outbox: $name.age already present"
else
  nice -n 19 age -R "$PUBKEY" -o "$enc.partial" "$SSD/$name"
  ( cd "$OUTBOX" && sha256sum "$name.age.partial" | sed 's/\.partial$//' > "$name.age.sha256" )
  chgrp "$PULL_GROUP" "$enc.partial" "$enc.sha256"
  chmod 640 "$enc.partial" "$enc.sha256"
  mv -- "$enc.partial" "$enc"
  log "outbox: encrypted $name.age ($(du -h "$enc" | cut -f1))"
fi
mapfile -t old < <(find "$OUTBOX" -maxdepth 1 -name 'jarvis_full_*.tar.gz.age' -printf '%T@ %p\n' | sort -rn | tail -n +"$((KEEP_OUT + 1))" | cut -d' ' -f2-)
for f in "${old[@]}"; do log "outbox retention: removing ${f##*/}"; rm -f -- "$f" "$f.sha256"; done
rm -f -- "$OUTBOX"/*.partial

log "SUCCESS: $name on SSD ($(find "$SSD" -maxdepth 1 -name 'jarvis_full_*.tar.gz' | wc -l) copies) + outbox"
