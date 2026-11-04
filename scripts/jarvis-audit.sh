#!/usr/bin/env bash
#
# jarvis-audit.sh - READ-ONLY configuration, health and security audit of the JARVIS node.
# v3.3 (2026-11-03): SSH accounts: keys in /etc/ssh/authorized_keys too (with key options), every
#                    account with a key + its effective sshd limits; system accounts (backuppull)
#                    must be chrooted read-only SFTP; secret test covers the SSD copies + outbox.
# v3.2 (2026-11-03): automatic-updates check reads APT::Periodic + apt-daily-upgrade.timer (v3.1
#                    checked the unattended-upgrades service and wrongly warned "not enabled");
#                    log-cap hint: daemon.json caps need a container recreate, not a restart.
# v3.1 (2026-10-20): ShellCheck clean (SC1087, SC2066), no behaviour change.
# v3 (2026-10-20): per-container log-cap check (daemon.json alone no longer counts), smbd running check, DNSSEC check.
#
#   sudo bash jarvis-audit.sh            # standard audit (about 1-3 minutes)
#   sudo bash jarvis-audit.sh --deep     # also verifies the newest backup archive (slow on USB 2.0)
#
# * Changes NOTHING on the system. The only file it writes is the report.
# * Report goes to ~/jarvis-audit-<timestamp>.txt (owner-only permissions).
# * Secrets are never printed: container env values are hidden unless on a
#   known-safe list, and config files pass through a redaction filter.
#   Skim the report before sharing it anyway (it contains IPs and hostnames).

set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

[[ $EUID -eq 0 ]] || { echo "Please run with sudo: sudo bash $0"; exit 1; }

DEEP=0
for a in "$@"; do [[ "$a" == "--deep" ]] && DEEP=1; done

# ----------------------------- configuration -----------------------------
STORAGE_MOUNT="/mnt/6TB_Storage"
BACKUP_ROOT="/mnt/6TB_Storage/jarvis_node_backups"
OLD_BACKUP_DIR="/mnt/6TB_Storage/homelab_backups"
PORTAINER_COMPOSE="/var/lib/docker/volumes/portainer_data/_data/compose"
BACKUP_SCRIPT="/usr/local/sbin/homelab-backup.sh"
KUMA_FILE="/root/.kuma_push_url"
KUMA_STORAGE_FILE="/root/.kuma_storage_push_url"
KUMA_DB="/home/admin/uptime-kuma_data/kuma.db"

# Container env vars whose VALUES are safe to print (everything else shows <hidden>)
SAFE_ENV_RE='^(TZ|PUID|PGID|UMASK|LANG|PATH|WATCHTOWER_[A-Z_]*(SCHEDULE|CLEANUP|MONITOR_ONLY|LABEL_ENABLE|POLL_INTERVAL|INCLUDE_RESTARTING|ROLLING_RESTART)|WG_PORT|WG_DEFAULT_ADDRESS|WG_MTU|WG_ALLOWED_IPS|WG_DEFAULT_DNS|WG_PERSISTENT_KEEPALIVE|CONTAINERS|SERVICES|TASKS|NETWORKS|IMAGES|INFO|VOLUMES|POST|SECRETS|EXEC|BUILD|COMMIT|CONFIGS|DISTRIBUTION|EVENTS|NODES|PLUGINS|SESSION|SWARM|SYSTEM|PING|VERSION|ALLOW_START|ALLOW_STOP|ALLOW_RESTARTS|LOG_LEVEL)$'

# ------------------------------ output setup -------------------------------
OWNER="${SUDO_USER:-root}"
OUTDIR="$(getent passwd "$OWNER" | cut -d: -f6)"; OUTDIR="${OUTDIR:-/root}"
OUT="$OUTDIR/jarvis-audit-$(date +%Y%m%d_%H%M%S).txt"
exec 3>&1                      # fd 3 = your terminal (progress + scorecard)
exec >"$OUT" 2>&1              # everything else goes into the report
trap 'chown "$OWNER" "$OUT" 2>/dev/null; chmod 600 "$OUT" 2>/dev/null' EXIT

# ------------------------------- helpers ----------------------------------
SECNUM=0
FINDINGS=()
have()    { command -v "$1" >/dev/null 2>&1; }
section() { SECNUM=$((SECNUM + 1)); printf '\n######## [%02d] %s ########\n' "$SECNUM" "$1"; printf '  [%02d] %s\n' "$SECNUM" "$1" >&3; }
finding() { printf '  >> [%s] %s\n' "$1" "$2"; FINDINGS+=("$1|$2"); }
rc()      { echo "\$ $*"; if have "$1"; then timeout 60 "$@" 2>&1; else echo "(not installed: $1)"; fi; echo; }
rf()      { echo "\$ $1"; "$@" 2>&1; echo; }
join()    { local IFS=', '; echo "$*"; }

redact() {
  sed -E \
    -e 's/((pass(word|wd|hash)?|psk|secret|token|salt|api_?key|private_?key|auth|credential|webhook|pwhash|cli_pw|key)[a-z0-9_.-]*[[:space:]]*[:=][[:space:]]*).*/\1<REDACTED>/I' \
    -e 's/\+[0-9]{8,15}/<PHONE>/g' \
    -e 's#(https?://[^[:space:]/:@]+:)[^@[:space:]]+@#\1<REDACTED>@#g'
}

# ------------------------- snippets used below -----------------------------
f_hostctl() { hostnamectl 2>&1 | grep -viE 'serial|machine id|boot id|hardware (vendor|model)'; }
smart_try() {   # smart_try <dev> : prints "<opt>|<output>" for the first mode that answers
  local d="$1" o opt
  for opt in "" "-d scsi" "-d sat"; do
    o="$(timeout 40 smartctl $opt -H "/dev/$d" 2>&1)"
    if grep -qE 'PASSED|FAILED|Status: OK|SMART Health Status' <<<"$o"; then SMART_OPT="$opt"; SMART_OUT="$o"; return 0; fi
  done
  SMART_OPT=""; SMART_OUT="$o"; return 1
}
as_nobody() { runuser -u nobody -- "$@" >/dev/null 2>&1; }   # can an unprivileged user do this?
f_osrel()   { grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME)=' /etc/os-release; }
f_cpu()     { lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Core)'; }
f_thermal() {
  local z
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r $z ]] && awk -v z="$z" '{printf "%s: %.1f C\n", z, $1/1000}' "$z"
  done
  have sensors && sensors 2>/dev/null | head -30
}
f_battery() {
  local b
  for b in /sys/class/power_supply/BAT*; do
    [[ -d $b ]] || continue
    echo "$(basename "$b"): status=$(cat "$b/status" 2>/dev/null) capacity=$(cat "$b/capacity" 2>/dev/null)% energy_full=$(cat "$b/energy_full" 2>/dev/null) design=$(cat "$b/energy_full_design" 2>/dev/null) cycles=$(cat "$b/cycle_count" 2>/dev/null)"
  done
  ls /sys/class/power_supply 2>/dev/null | tr '\n' ' '; echo
}
f_sleep() {
  grep -hE '^\s*Handle(LidSwitch|LidSwitchExternalPower|PowerKey)' /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null || echo "(logind defaults: lid close = suspend)"
  local t
  for t in sleep suspend hibernate hybrid-sleep; do printf '%s.target: ' "$t"; systemctl is-enabled "$t.target" 2>&1; done
}
f_users()   { getent passwd | awk -F: '$3>=1000 && $3<65000 {print $1" uid="$3" shell="$7}'; }
f_sudoers() { grep -rnE 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null || echo "no NOPASSWD rules"; }
f_sshd()    { sshd -T 2>/dev/null | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|x11forwarding|maxauthtries|allowusers|allowgroups|permitemptypasswords) '; }
KEYFILES=(/home/*/.ssh/authorized_keys /root/.ssh/authorized_keys /etc/ssh/authorized_keys/*)
nkeys() { grep -cvE '^\s*(#|$)' "$1" 2>/dev/null; }
f_sshkeys() {   # v3.3: also /etc/ssh/authorized_keys/<user>; shows key options (restrict, from=...), never the keys
  local f opts
  for f in "${KEYFILES[@]}"; do
    [[ -f $f ]] || continue
    opts="$(grep -vE '^\s*(#|$)' "$f" | awk '$1 !~ /^(ssh-|ecdsa-|sk-)/ {print $1}' | sort -u | tr '\n' ' ')"
    echo "$f: $(nkeys "$f") key(s), perms $(stat -c '%a %U' "$f")${opts:+, options: $opts}"
  done
}
ssh_key_users() {   # accounts with at least one authorized key (any uid)
  local f
  for f in "${KEYFILES[@]}"; do
    [[ -f $f ]] && (( $(nkeys "$f") > 0 )) || continue
    if [[ $f == /etc/ssh/authorized_keys/* ]]; then echo "${f##*/}"; else stat -c %U "$f"; fi
  done | sort -u
}
sshd_for() { sshd -T -C "user=$1,host=audit,addr=192.168.1.20" 2>/dev/null; }   # effective sshd settings for a user (from the PC)
f_sshaccounts() {
  local u
  for u in $(ssh_key_users); do
    getent passwd "$u" >/dev/null || { echo "$u: key file but NO such account"; continue; }
    echo "$u uid=$(id -u "$u") shell=$(getent passwd "$u" | cut -d: -f7) password=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
    sshd_for "$u" | grep -E '^(chrootdirectory|forcecommand|passwordauthentication|allowtcpforwarding|permittty) ' | sed 's/^/    /'
  done
}
f_fstab()   { grep -vE '^\s*(#|$)' /etc/fstab; }
f_ext4() {
  local dev; dev="$(findmnt -no SOURCE "$STORAGE_MOUNT" 2>/dev/null)"
  [[ -n $dev ]] || { echo "$STORAGE_MOUNT not mounted"; return; }
  echo "device: $dev"
  tune2fs -l "$dev" 2>/dev/null | grep -E 'Filesystem (state|features)|Errors behavior|Mount count|Last checked|Lifetime writes'
}
f_smart() {
  have smartctl || { echo "smartctl not installed"; return; }
  local d
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    echo "--- /dev/$d ($(lsblk -dno MODEL,SIZE "/dev/$d" 2>/dev/null))"
    if smart_try "$d"; then
      echo "mode: ${SMART_OPT:-auto}"
      grep -E 'overall-health|Health Status' <<<"$SMART_OUT" | head -2
      timeout 40 smartctl $SMART_OPT -A "/dev/$d" 2>&1 | grep -E 'Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours|Temperature_Celsius|Wear_Leveling|Percent_Lifetime|UDMA_CRC|grown defect|Current Drive Temperature|Accumulated power on|Non-medium error|Elements in grown'
    else
      echo "SMART not readable in any mode (auto, scsi, sat)"
    fi
  done
}
f_dmesg_disk() { dmesg -T 2>/dev/null | grep -iE 'I/O error|ext4-fs error|ata[0-9.]+: (failed|error)|Buffer I/O|critical medium|usb.*(disconnect|reset)' | tail -15; }
f_dirsizes() { timeout 180 du -sh --max-depth=1 "$STORAGE_MOUNT" 2>/dev/null; du -sh /var/lib/docker /var/log /opt /home 2>/dev/null; }
f_resolv()  { grep -vE '^\s*(#|$)' /etc/resolv.conf; resolvectl status 2>/dev/null | grep -E 'Link|DNS Server|Current DNS' | head -12; }
f_netplan() { cat /etc/netplan/*.yaml 2>/dev/null | redact; }
f_ufw_rules() { ufw status verbose 2>&1; echo; ufw status numbered 2>&1; }
f_ipt_docker() {
  echo "--- DOCKER-USER";        iptables -S DOCKER-USER 2>&1
  echo "--- ufw-user-forward";   iptables -S ufw-user-forward 2>&1
  echo "--- NAT port mappings";  iptables -t nat -S DOCKER 2>&1 | grep -E 'DNAT' 
}
f_docker_info() {
  docker version --format 'client={{.Client.Version}} server={{.Server.Version}}' 2>&1
  docker info --format 'storage={{.Driver}} cgroup={{.CgroupVersion}} logging={{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}} root={{.DockerRootDir}} containers={{.Containers}} running={{.ContainersRunning}}' 2>&1
  echo "--- /etc/docker/daemon.json"; redact < /etc/docker/daemon.json 2>/dev/null || echo "(none)"
}
f_networks() {
  local n
  for n in $(docker network ls --format '{{.Name}}'); do
    docker network inspect -f '{{.Name}}: driver={{.Driver}} internal={{.Internal}} subnet={{range .IPAM.Config}}{{.Subnet}} {{end}}members=[{{range .Containers}}{{.Name}} {{end}}]' "$n"
  done
}
f_container() {   # f_container <name>
  docker inspect -f '  image:      {{.Config.Image}}
  image-id:   {{.Image}}
  created:    {{.Created}}
  started:    {{.State.StartedAt}}
  state:      {{.State.Status}} restarts={{.RestartCount}} oom-killed={{.State.OOMKilled}}
  restart:    {{.HostConfig.RestartPolicy.Name}}
  net-mode:   {{.HostConfig.NetworkMode}}
  privileged: {{.HostConfig.Privileged}}   read-only-rootfs: {{.HostConfig.ReadonlyRootfs}}
  user:       {{if .Config.User}}{{.Config.User}}{{else}}(image default){{end}}
  cap-add:    {{.HostConfig.CapAdd}}   cap-drop: {{.HostConfig.CapDrop}}   security-opt: {{.HostConfig.SecurityOpt}}
  devices:    {{range .HostConfig.Devices}}{{.PathOnHost}}->{{.PathInContainer}} {{end}}
  limits:     memory={{.HostConfig.Memory}} nano-cpus={{.HostConfig.NanoCpus}}
  log:        {{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}
  networks:   {{range $k,$v := .NetworkSettings.Networks}}{{$k}}({{$v.IPAddress}}) {{end}}
  ports:      {{range $p,$b := .HostConfig.PortBindings}}{{$p}}->{{range $b}}{{if .HostIp}}{{.HostIp}}{{else}}0.0.0.0{{end}}:{{.HostPort}} {{end}}{{end}}
  mounts:{{range .Mounts}}
     {{.Type}} {{.Source}} -> {{.Destination}} (rw={{.RW}}){{end}}
  compose:    project={{index .Config.Labels "com.docker.compose.project"}} file={{index .Config.Labels "com.docker.compose.project.config_files"}}' "$1"
  echo "  status:     $(docker ps -a --filter "name=^/$1\$" --format '{{.Status}}')"
  echo "  env (values hidden unless on the safe list):"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | while IFS= read -r l; do
    [[ -z $l ]] && continue
    k="${l%%=*}"
    if [[ $k =~ $SAFE_ENV_RE ]]; then echo "     $l"; else echo "     $k=<hidden>"; fi
  done
  echo "  errors in last 24h: $(docker logs --since 24h "$1" 2>&1 | grep -ciE 'error|fatal|panic|exception')"
  docker logs --since 24h "$1" 2>&1 | grep -iE 'error|fatal|panic|exception' | tail -3 | cut -c1-220 | redact | sed 's/^/     log: /'
}
f_stacks() {
  local d f
  for d in $(ls -1 "$PORTAINER_COMPOSE" 2>/dev/null | sort -n); do
    echo "=== Portainer stack #$d  ($(ls -A "$PORTAINER_COMPOSE/$d" | tr '\n' ' '))"
    f="$PORTAINER_COMPOSE/$d/docker-compose.yml"
    [[ -f $f ]] && redact < "$f"
    [[ -f "$PORTAINER_COMPOSE/$d/stack.env" ]] && { echo "--- stack.env (names only)"; sed -E 's/=.*/=<hidden>/' "$PORTAINER_COMPOSE/$d/stack.env"; }
    [[ -f "$PORTAINER_COMPOSE/$d/.env" ]] && { echo "--- .env (names only)"; sed -E 's/=.*/=<hidden>/' "$PORTAINER_COMPOSE/$d/.env"; }
    echo
  done
}
f_samba() {
  have testparm || { echo "testparm not installed"; return; }
  testparm -s 2>/dev/null | redact
  echo "--- key effective settings"
  testparm -sv 2>/dev/null | grep -E 'server min protocol|server max protocol|map to guest|restrict anonymous|guest ok|read only|valid users' | sort | uniq -c
  echo "--- samba users"; pdbedit -L 2>&1 | cut -d: -f1
  echo "--- connections"; smbstatus -b 2>&1 | head -10
}
f_cron() {
  echo "--- root crontab";  crontab -l 2>&1 | grep -vE '^\s*(#|$)'
  local u
  for u in $(getent passwd | awk -F: '$3>=1000 && $3<65000{print $1}'); do
    echo "--- crontab of $u"; crontab -l -u "$u" 2>&1 | grep -vE '^\s*(#|$)'
  done
  echo "--- /etc/cron.d"; ls -l /etc/cron.d 2>&1
  echo "--- systemd timers"; systemctl list-timers --all --no-pager 2>&1 | head -25
}
f_rootscripts() {
  local f
  for f in /usr/local/bin/update-ub "$BACKUP_SCRIPT"; do
    [[ -f $f ]] || continue
    echo "=== $f  ($(stat -c '%a %U:%G %y' "$f"))  sha256=$(sha256sum "$f" | cut -c1-16)"
    redact < "$f"
    echo
  done
}
f_backups() {
  echo "--- $BACKUP_ROOT"; ls -lh "$BACKUP_ROOT" 2>&1 | tail -20
  echo "--- old job folder: $OLD_BACKUP_DIR"; ls -lh "$OLD_BACKUP_DIR" 2>&1 | tail -5
  echo "--- staging leftovers"; ls -A /var/backups/homelab-stage 2>&1
  echo "--- kuma push file"; stat -c '%n  perms=%a owner=%U' "$KUMA_FILE" 2>&1
  echo "--- backup log (last 15 lines)"; tail -15 /var/log/homelab-backup.log 2>&1
}

# =============================== AUDIT ====================================
echo "JARVIS AUDIT - $(date '+%F %T %Z') - script v3.3 - deep=$DEEP"
echo "(read-only; secrets redacted; see end of file for the scorecard)"

# ---------------------------------------------------------------- 1
section "System overview"
rc date
rf f_hostctl
rf f_osrel
rc uname -a
rc uptime
rf f_cpu
rc free -h
rc swapon --show
rf f_thermal
rf f_battery
rf f_sleep

if [[ "$(systemctl is-enabled suspend.target 2>/dev/null)" == "masked" ]]; then
  finding PASS "suspend is masked: the server will not sleep"
else
  finding WARN "suspend.target is not masked: closing the lid or an idle trigger could suspend the server"
fi
if ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
  bf=$(cat /sys/class/power_supply/BAT0/energy_full 2>/dev/null); bd=$(cat /sys/class/power_supply/BAT0/energy_full_design 2>/dev/null)
  bs=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
  if [[ $bf =~ ^[0-9]+$ && $bd =~ ^[0-9]+$ && $bd -gt 0 ]]; then
    bh=$(( bf * 100 / bd ))
    (( bh >= 70 )) && finding PASS "laptop battery (acts as the host's UPS): health ${bh}% of design, status ${bs:-unknown}" \
                   || finding WARN "laptop battery health is ${bh}% of design (status ${bs:-unknown}): runtime in an outage will be short"
  else
    finding INFO "laptop battery present (status ${bs:-unknown}); health could not be computed"
  fi
  [[ $bs == "Full" || $bs == "Charging" || $bs == "Not charging" ]] || finding WARN "battery status is '${bs:-unknown}': the host may be running on battery or the battery is faulty"
fi

# ---------------------------------------------------------------- 2
section "OS, updates and reboot state"
rc cat /var/run/reboot-required
UPG="$(apt list --upgradable 2>/dev/null | tail -n +2)"
echo "\$ apt list --upgradable"; echo "$UPG"; echo
rc stat -c 'last apt update: %y' /var/lib/apt/periodic/update-success-stamp
rc apt-config shell UU APT::Periodic::Unattended-Upgrade
rc systemctl is-enabled apt-daily-upgrade.timer
rc grep -h -B1 'Commandline: /usr/bin/unattended-upgrade' /var/log/apt/history.log
rc apt-mark showhold
rc systemctl --failed --no-pager

[[ -f /var/run/reboot-required ]] && finding WARN "a reboot is pending (kernel/library updates not yet active)" || finding PASS "no reboot pending"
n_up=$(grep -c . <<<"$UPG"); n_sec=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst .*-security')
(( n_sec > 0 )) && finding WARN "$n_sec package(s) would be updated from a security pocket (as of the last apt update)" || finding PASS "no pending security updates (as of the last apt update)"
RUNK="$(uname -r)"; NEWK="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1)"
[[ -n $NEWK && $NEWK != "$RUNK" ]] && finding WARN "running kernel $RUNK, newest installed kernel is $NEWK (reboot to activate)" || finding PASS "running the newest installed kernel ($RUNK)"
(( n_up  > 0 )) && finding INFO "$n_up package update(s) available in total"
# v3.2: the unattended-upgrades service only finishes installs at shutdown; the daily
# runs come from apt-daily-upgrade.timer + APT::Periodic::Unattended-Upgrade.
UU_CFG="$(apt-config shell UU APT::Periodic::Unattended-Upgrade 2>/dev/null | sed -E "s/^UU='(.*)'$/\1/")"
[[ "${UU_CFG:-0}" != "0" && "$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null)" == "enabled" ]] \
  && finding PASS "automatic security updates on (daily unattended-upgrade; kernels still need a reboot)" \
  || finding WARN "automatic security updates are off (APT::Periodic::Unattended-Upgrade or apt-daily-upgrade.timer)"
n_failed=$(systemctl --failed --no-legend 2>/dev/null | grep -c .)
(( n_failed == 0 )) && finding PASS "no failed systemd units" || finding WARN "$n_failed failed systemd unit(s)"

# ---------------------------------------------------------------- 3
section "Access and authentication"
rc who
rc last -n 10 -w
rc lastb -n 10 -w
rc getent group sudo docker adm
rf f_users
rf f_sudoers
rf f_sshd
rf f_sshkeys
rf f_sshaccounts
rc timedatectl
have fail2ban-client && rc fail2ban-client status || echo "(fail2ban not installed)"

SSHD="$(sshd -T 2>/dev/null)"
sshval() { awk -v k="$1" '$1==k{print $2; exit}' <<<"$SSHD"; }
if [[ -n $SSHD ]]; then
  v="$(sshval permitrootlogin)"
  [[ $v == no || $v == prohibit-password ]] && finding PASS "ssh: root login = $v" || finding WARN "ssh: root login = $v"
  v="$(sshval passwordauthentication)"
  [[ $v == no ]] && finding PASS "ssh: password authentication disabled (key-only)" || finding WARN "ssh: password authentication is enabled (key-only is the standard)"
else
  finding INFO "could not read effective sshd configuration"
fi
[[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] \
  && finding PASS "clock is NTP-synchronised" || finding WARN "clock is not NTP-synchronised"
dgroup="$(getent group docker | cut -d: -f4)"
[[ -n $dgroup ]] && finding INFO "members of the docker group (root-equivalent): $dgroup"
# v3.3: every account with an SSH key; system accounts (uid < 1000, not root) must be locked down
keyusers="$(ssh_key_users | tr '\n' ' ')"
finding INFO "accounts with SSH keys: ${keyusers:-none}"
for u in $keyusers; do
  uid="$(id -u "$u" 2>/dev/null)" || { finding WARN "ssh: key file for $u, but no such account"; continue; }
  (( uid >= 1000 || uid == 0 )) && continue
  t="$(sshd_for "$u")"; bad=()
  chroot="$(awk '$1=="chrootdirectory"{print $2}' <<<"$t")"
  fcmd="$(awk '$1=="forcecommand"{$1=""; print substr($0,2)}' <<<"$t")"
  [[ -n $chroot && $chroot != none ]] || bad+=("no chroot")
  [[ $fcmd == "internal-sftp -R" ]] || bad+=("forcecommand '${fcmd:-none}' (expected internal-sftp -R)")
  [[ "$(awk '$1=="passwordauthentication"{print $2}' <<<"$t")" == no ]] || bad+=("password login allowed")
  [[ "$(awk '$1=="allowtcpforwarding"{print $2}' <<<"$t")" == no ]] || bad+=("TCP forwarding allowed")
  [[ "$(awk '$1=="permittty"{print $2}' <<<"$t")" == no ]] || bad+=("TTY allowed")
  [[ "$(getent passwd "$u" | cut -d: -f7)" == */nologin || "$(getent passwd "$u" | cut -d: -f7)" == */false ]] || bad+=("login shell")
  if [[ -n $chroot && $chroot != none ]]; then
    [[ "$(stat -c %U "$chroot" 2>/dev/null)" == root ]] && (( ( 8#$(stat -c %a "$chroot") & 8#022 ) == 0 )) || bad+=("chroot $chroot not root-owned / writable by others")
  fi
  if (( ${#bad[@]} == 0 )); then finding PASS "ssh: system account $u is locked down (key only, chroot $chroot, read-only SFTP, no TTY/forwarding)"
  else finding WARN "ssh: system account $u is NOT locked down: ${bad[*]}"; fi
done

echo "--- secret exposure test (as the unprivileged user 'nobody'; file contents are never read out)"
EXPO=0
for sp in /opt/nextcloud/config/keys/cert.key /opt/nextcloud/config/www/nextcloud/config/config.php /etc/pihole/pihole.toml /etc/pihole/cli_pw /etc/pihole/tls.pem /etc/pihole/pihole-FTL.db /home/admin/wg_easy /home/admin/signal-api/data "$OLD_BACKUP_DIR" "$BACKUP_ROOT" /var/backups/jarvis_node_backups /var/backups/jarvis_outbox/files /root/.kuma_push_url /var/backups/rescue-20261011; do
  [[ -e $sp ]] || { echo "absent    $sp"; continue; }
  if [[ -d $sp ]]; then as_nobody ls "$sp" && r=1 || r=0; else as_nobody head -c1 "$sp" && r=1 || r=0; fi
  if (( r )); then echo "EXPOSED   $sp"; EXPO=$((EXPO+1)); else echo "protected $sp"; fi
done
(( EXPO == 0 )) && finding PASS "secret exposure test: none of the checked secret paths are readable by an unprivileged user" \
                || finding WARN "secret exposure test: $EXPO checked secret path(s) are readable by an unprivileged user (see section 3)"
echo

# ---------------------------------------------------------------- 4
section "Storage and disk health"
rc lsblk -f
rc df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay
rc df -i -x tmpfs -x devtmpfs -x squashfs -x overlay
rf f_fstab
rf f_ext4
rf f_smart
rf f_dmesg_disk
rf f_dirsizes

maxpct=0
while read -r pct tgt; do
  p="${pct%\%}"; [[ $p =~ ^[0-9]+$ ]] || continue
  (( p > maxpct )) && maxpct=$p
  if   (( p >= 90 )); then finding FAIL "filesystem $tgt is ${p}% full"
  elif (( p >= 80 )); then finding WARN "filesystem $tgt is ${p}% full"
  fi
done < <(df --output=pcent,target -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
(( maxpct < 80 )) && finding PASS "all filesystems below 80% (highest ${maxpct}%)"

if have smartctl; then
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    if smart_try "$d"; then
      if   grep -q 'FAILED' <<<"$SMART_OUT"; then finding FAIL "SMART health FAILED on /dev/$d"
      else finding PASS "SMART health passed on /dev/$d (mode: ${SMART_OPT:-auto})"; fi
    else
      finding WARN "could not read SMART data for /dev/$d in any mode"
    fi
  done
else
  finding WARN "smartmontools is not installed: disk health is unverified (sudo apt install smartmontools)"
fi
n_io=$(dmesg -T 2>/dev/null | grep -ciE 'I/O error|ext4-fs error|Buffer I/O|critical medium|ata[0-9.]+: (failed|error)')
(( n_io > 0 )) && finding WARN "$n_io disk/filesystem error line(s) in the kernel log" || finding PASS "no disk I/O errors in the kernel log"
mountpoint -q "$STORAGE_MOUNT" && finding PASS "$STORAGE_MOUNT is mounted" || finding FAIL "$STORAGE_MOUNT is NOT mounted"
grep -qE "[[:space:]]${STORAGE_MOUNT}[[:space:]].*nofail" /etc/fstab \
  && finding PASS "fstab entry for $STORAGE_MOUNT uses nofail" \
  || finding INFO "fstab entry for $STORAGE_MOUNT lacks 'nofail' (boot can hang if the drive is absent)"

# ---------------------------------------------------------------- 5
section "Network and firewall"
rc ip -br address
rc ip route
rf f_resolv
rf f_netplan
rc sysctl net.ipv4.ip_forward
rf f_ufw_rules
rf f_ipt_docker
rc ss -tulpn

defdev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
[[ $defdev == wl* ]] && finding WARN "default route uses Wi-Fi ($defdev): a server should be on wired Ethernet" \
                     || finding PASS "default route interface: ${defdev:-none}"
if ufw status 2>/dev/null | grep -q 'Status: active'; then
  finding PASS "ufw firewall is active"
  ufw status verbose 2>/dev/null | grep -q 'deny (incoming)' && finding PASS "ufw default incoming policy: deny" || finding WARN "ufw default incoming policy is not deny"
else
  finding FAIL "ufw firewall is not active"
fi
grep -q 'DOCKER-USER' /etc/ufw/after.rules 2>/dev/null \
  && finding PASS "ufw is integrated with Docker via the DOCKER-USER chain" \
  || finding WARN "no DOCKER-USER integration found in /etc/ufw/after.rules (published container ports may bypass ufw)"
n_any=$(iptables -S ufw-user-forward 2>/dev/null | grep -- '^-A' | grep -vc -- ' -s ')
(( n_any > 0 )) && finding WARN "$n_any ufw route rule(s) accept traffic from ANY source (no -s restriction)" \
                || finding PASS "all ufw route rules restrict their source"

# ---------------------------------------------------------------- 6
HAVE_DOCKER=0; have docker && docker info >/dev/null 2>&1 && HAVE_DOCKER=1
section "Docker engine, images and networks"
if (( HAVE_DOCKER )); then
  rf f_docker_info
  rc docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  rc docker images --digests --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'
  rc docker system df
  rf f_networks
  rc docker volume ls
  echo "\$ largest container log files"; du -h /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -rh | head -5; echo
else
  echo "Docker is not available."; finding FAIL "docker is not running or not installed"
fi

# ---------------------------------------------------------------- 7
section "Containers (one block each)"
CONTS=()
(( HAVE_DOCKER )) && mapfile -t CONTS < <(docker ps -a --format '{{.Names}}' | sort)
BLOCKS_OK=0
for c in "${CONTS[@]}"; do
  echo "--- $c"
  if blk="$(f_container "$c" 2>&1)" && ! grep -q 'template parsing error' <<<"$blk"; then
    BLOCKS_OK=$((BLOCKS_OK + 1)); echo "$blk"
  else
    echo "$blk" | head -5; echo "  (block incomplete: see message above)"
  fi
  echo
done
(( HAVE_DOCKER )) && rc docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'

if (( HAVE_DOCKER )); then
  SOCK=(); PRIV=(); NOHC=(); LATEST=(); NOROT=(); EXPOSED=(); DOWN=(); PROXY=()
  grep -q '"max-size"' /etc/docker/daemon.json 2>/dev/null && DAEMON_ROT=1 || DAEMON_ROT=0
  for c in "${CONTS[@]}"; do
    [[ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}Y{{end}}{{end}}' "$c")" == *Y* ]] && SOCK+=("$c")
    [[ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$c")" == true ]] && PRIV+=("$c")
    docker inspect -f '{{json .State}}' "$c" 2>/dev/null | grep -q '"Health"' || NOHC+=("$c")
    img="$(docker inspect -f '{{.Config.Image}}' "$c")"
    [[ "$img" == *:latest || "$img" != *[:@]* ]] && LATEST+=("$c")
    [[ "$img" == *socket-proxy* ]] && PROXY+=("$c")
    [[ "$(docker inspect -f '{{.State.Status}}' "$c")" == running ]] || DOWN+=("$c")
    lt="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$c")"
    ms="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' "$c" 2>/dev/null)"
    [[ "$lt" == json-file && -z "$ms" ]] && NOROT+=("$c")   # v3: per container (daemon.json only applies to containers created after a Docker restart)
    for b in $(docker inspect -f '{{range $p,$bs := .HostConfig.PortBindings}}{{range $bs}}{{if or (not .HostIp) (eq .HostIp "0.0.0.0")}}{{.HostPort}} {{end}}{{end}}{{end}}' "$c"); do
      EXPOSED+=("$c:$b")
    done
  done
  (( BLOCKS_OK == ${#CONTS[@]} )) && finding PASS "all ${#CONTS[@]} container detail blocks were collected" \
    || finding WARN "only $BLOCKS_OK of ${#CONTS[@]} container detail blocks were collected (see section 7)"
  (( ${#DOWN[@]}   )) && finding WARN "containers not running: $(join "${DOWN[@]}")"   || finding PASS "all containers are running"
  unh="$(docker ps --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')"
  [[ -n $unh ]] && finding FAIL "unhealthy containers: $unh" || finding PASS "no unhealthy containers"
  (( ${#SOCK[@]}   )) && finding WARN "containers with the raw Docker socket mounted (root-equivalent on the host): $(join "${SOCK[@]}")"
  (( ${#PRIV[@]}   )) && finding WARN "privileged containers: $(join "${PRIV[@]}")" || finding PASS "no privileged containers"
  (( ${#LATEST[@]} )) && finding INFO "images not pinned to a version tag (:latest or untagged): $(join "${LATEST[@]}")"
  (( ${#NOHC[@]}   )) && finding INFO "containers without a healthcheck: $(join "${NOHC[@]}")"
  (( ${#NOROT[@]}  )) && finding WARN "json-file logs without a size cap (can fill the disk): $(join "${NOROT[@]}")$( (( DAEMON_ROT )) && echo " (daemon.json has caps: they apply only to containers created after that, so recreate these; a Docker restart or reboot does not)")" || finding PASS "container log rotation is configured"
  (( ${#EXPOSED[@]} )) && finding INFO "ports published on ALL interfaces: $(join "${EXPOSED[@]}")"
  for c in "${PROXY[@]}"; do
    flags="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -E '^(POST|EXEC|BUILD|COMMIT|SECRETS|AUTH|SWARM|NODES|SYSTEM|VOLUMES|NETWORKS|IMAGES|CONTAINERS)=1' | tr '\n' ' ')"
    finding INFO "docker socket proxy '$c' permissions enabled: ${flags:-none}"
  done
fi

# ---------------------------------------------------------------- 8
section "Compose stacks (Portainer, secrets redacted)"
rf f_stacks

# ---------------------------------------------------------------- 9
section "Service health checks"
if (( HAVE_DOCKER )); then
  has() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
  if has pihole; then
    echo "--- Pi-hole"
    timeout 20 docker exec pihole pihole -v 2>&1 | head -5
    echo "upstreams:"; timeout 20 docker exec pihole sh -c 'pihole-FTL --config dns.upstreams 2>/dev/null || grep -h "^server=" /etc/dnsmasq.d/*.conf' 2>&1
    r1="$(timeout 20 docker exec pihole dig +time=3 +tries=1 +short @127.0.0.1 example.com 2>&1 | head -1)"
    r2="$(timeout 20 docker exec pihole dig +time=3 +tries=1 +short @127.0.0.1 doubleclick.net 2>&1 | head -1)"
    echo "resolve example.com      -> ${r1:-<none>}"
    echo "resolve doubleclick.net  -> ${r2:-<none>}"
    [[ $r1 =~ ^[0-9a-f:.]+$ ]] && finding PASS "Pi-hole resolves public names (example.com -> $r1)" || finding FAIL "Pi-hole could not resolve example.com ($r1)"
    case "$r2" in ""|0.0.0.0|::) finding PASS "Pi-hole is blocking ad domains (doubleclick.net -> ${r2:-blocked})";;
                  *) finding INFO "doubleclick.net resolved normally ($r2): check blocklists";; esac
    # v3: DNSSEC validation (Unbound). A random name under the deliberately mis-signed zone must be refused.
    if have dig; then
      ds="$(dig +time=3 +tries=1 @127.0.0.1 "chk${RANDOM}.dnssec-failed.org" A 2>/dev/null | grep -oE 'status: [A-Z]+' | cut -d' ' -f2)"
      case "$ds" in SERVFAIL) finding PASS "DNSSEC validation active (mis-signed domain refused)";;
                    NOERROR|NXDOMAIN) finding FAIL "DNSSEC validation is OFF (mis-signed domain answered $ds)";;
                    *) finding INFO "DNSSEC check got no answer (${ds:-timeout})";; esac
    fi
    echo
  fi
  if has unbound; then
    echo "--- Unbound config (host file)"; redact < /home/admin/unbound_config/pi-hole.conf 2>/dev/null | head -60
    timeout 20 docker exec unbound unbound-checkconf 2>&1 | head -3
    echo
  fi
  if has wg-easy; then
    echo "--- WireGuard"; timeout 20 docker exec wg-easy wg show 2>&1; echo
  fi
  if has nextcloud; then
    echo "--- Nextcloud"
    nc_out="$(timeout 60 docker exec nextcloud occ status 2>&1)"
    if ! grep -q 'installed' <<<"$nc_out"; then
      nc_out="$(timeout 60 docker exec -u abc nextcloud php /config/www/nextcloud/occ status 2>&1)"
    fi
    head -12 <<<"$nc_out"
    echo "trusted_domains:"; timeout 60 docker exec nextcloud occ config:system:get trusted_domains 2>&1 | head -6
    echo
  fi
  echo "--- HTTP probes from the host (status codes only)"
  for probe in "plex:http://127.0.0.1:32400/identity" "kuma:http://127.0.0.1:3001/" "homepage:http://127.0.0.1:3000/" "pihole-ui:http://127.0.0.1:8053/admin/" "signal-api:http://127.0.0.1:8081/v1/about"; do
    name="${probe%%:*}"; url="${probe#*:}"
    code="$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$url" 2>/dev/null)"
    echo "$name $url -> HTTP ${code:-000}"
  done
  echo
  has plex && { echo "--- Plex"; timeout 20 docker exec plex ls /data/media 2>&1 | head -10; echo "render devices:"; ls -l /dev/dri 2>&1; echo; }
  has duckdns && { echo "--- DuckDNS last log lines"; docker logs --tail 3 duckdns 2>&1 | redact | cut -c1-160; echo; }
  has watchtower && { echo "--- Watchtower activity (7 days)"; docker logs --since 168h watchtower 2>&1 | grep -iE 'updat|found|error|session done|fail|created' | tail -15 | cut -c1-240 | redact; echo; }

  code="$(curl -s -o /dev/null -m 6 -w '%{http_code}' http://127.0.0.1:32400/identity 2>/dev/null)"
  has plex && { [[ $code == 200 ]] && finding PASS "Plex answers on :32400" || finding WARN "Plex did not answer on :32400 (HTTP ${code:-000})"; }
  code="$(curl -s -o /dev/null -m 6 -w '%{http_code}' http://127.0.0.1:3001/ 2>/dev/null)"
  has uptime-kuma && { [[ $code =~ ^(200|302)$ ]] && finding PASS "Uptime Kuma answers on :3001" || finding WARN "Uptime Kuma did not answer (HTTP ${code:-000})"; }
fi
echo "--- Samba"; f_samba; echo
if have testparm; then
  minp="$(testparm -sv 2>/dev/null | awk -F= '/server min protocol/{gsub(/ /,"",$2); print $2; exit}')"
  case "$minp" in NT1|CORE|COREPLUS|LANMAN1|LANMAN2) finding FAIL "Samba allows SMB1 (server min protocol = $minp)";;
                  "") finding INFO "could not determine Samba minimum protocol";;
                  *)  finding PASS "Samba minimum protocol is $minp (SMB1 disabled)";; esac
  testparm -sv 2>/dev/null | grep -qE 'guest ok = Yes' && finding WARN "a Samba share allows guest (anonymous) access"
fi
systemctl is-active --quiet smbd && finding PASS "Samba (smbd) is running" || finding FAIL "Samba (smbd) is NOT running"
ls /dev/dri/renderD* >/dev/null 2>&1 && finding PASS "a GPU render node exists (hardware transcoding possible)" \
  || finding INFO "no /dev/dri/renderD* render node: Plex hardware transcoding is not available on this hardware"

# ---------------------------------------------------------------- 10
section "Scheduled jobs and root-run scripts"
rf f_cron
rf f_rootscripts
echo "\$ files under /usr/local/{bin,sbin} that are group/world-writable or not root-owned"
find /usr/local/bin /usr/local/sbin -type f \( -perm /022 -o ! -user root \) -printf '%m %u %p\n' 2>/dev/null; echo
n_bad=$(find /usr/local/bin /usr/local/sbin -type f \( -perm /022 -o ! -user root \) 2>/dev/null | grep -c .)
(( n_bad > 0 )) && finding WARN "$n_bad script(s) in /usr/local/{bin,sbin} are writable by non-root or not root-owned (privilege-escalation risk if root runs them)" \
                || finding PASS "root-run scripts in /usr/local are root-owned and not writable by others"

# ---------------------------------------------------------------- 11
section "Backups"
rf f_backups
NEWEST="$(find "$BACKUP_ROOT" -maxdepth 1 -name 'jarvis_full_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1)"
if [[ -n $NEWEST ]]; then
  ts="${NEWEST%% *}"; nf="${NEWEST#* }"; age_h=$(( ( $(date +%s) - ${ts%.*} ) / 3600 ))
  echo "newest archive: $nf  (age ${age_h}h)"
  (( age_h <= 30 )) && finding PASS "newest backup is ${age_h}h old" \
    || { (( age_h <= 54 )) && finding WARN "newest backup is ${age_h}h old (expected < 30h)" || finding FAIL "newest backup is ${age_h}h old: the nightly job is not producing archives"; }
  [[ -f "$nf.sha256" ]] && finding PASS "checksum file present for the newest archive" || finding WARN "no .sha256 file beside the newest archive"
  perms="$(stat -c '%a %U' "$nf")"
  [[ $perms == "600 root" ]] && finding PASS "newest archive is root-only (600)" || finding WARN "newest archive permissions are $perms (expected 600 root)"
  if (( DEEP )); then
    echo "--- deep verification of $nf"
    if ( cd "$BACKUP_ROOT" && sha256sum -c "$(basename "$nf").sha256" ) 2>&1; then
      finding PASS "deep check: archive matches its SHA-256"
    else
      finding FAIL "deep check: archive does NOT match its SHA-256"
    fi
    tar -tzf "$nf" > /tmp/.jarvis-audit-listing.$$ 2>&1
    for p in /opt/plex/config /opt/nextcloud/config /mnt/6TB_Storage/nextcloud_data /home/admin/wg_easy /home/admin/uptime-kuma_data /home/admin/signal-api /etc/pihole /var/lib/docker/volumes/portainer_data; do
      grep -qF "./data$p/" /tmp/.jarvis-audit-listing.$$ && echo "  in archive: $p" || { echo "  MISSING: $p"; finding FAIL "deep check: $p is missing from the newest archive"; }
    done
    rm -f /tmp/.jarvis-audit-listing.$$
  else
    finding INFO "archive contents/checksum not re-verified (run with --deep to do so)"
  fi
else
  finding FAIL "no archives found in $BACKUP_ROOT"
fi
[[ -x $BACKUP_SCRIPT ]] && finding PASS "backup script installed and executable" || finding FAIL "backup script missing or not executable"
crontab -l 2>/dev/null | grep -v '^\s*#' | grep -q 'homelab-backup' \
  && finding PASS "root crontab schedules the new backup job" || finding WARN "the new backup job is NOT scheduled in root's crontab"
[[ "$(stat -c '%a %U' "$KUMA_FILE" 2>/dev/null)" == "600 root" ]] \
  && finding PASS "Uptime Kuma push URL stored root-only (600)" || finding WARN "Kuma push URL file missing or not 600 root"
for u in $(getent passwd | awk -F: '$3>=1000 && $3<65000{print $1}'); do
  crontab -l -u "$u" 2>/dev/null | grep -v '^\s*#' | grep -q 'homelab_backup.sh' \
    && finding WARN "old backup job (homelab_backup.sh) is still active in $u's crontab"
done
if [[ -d $OLD_BACKUP_DIR ]]; then
  as_nobody ls "$OLD_BACKUP_DIR" \
    && finding WARN "old archives folder $OLD_BACKUP_DIR is readable by unprivileged users (they contain Signal keys); delete them once the new backups are proven" \
    || finding INFO "old archives folder $OLD_BACKUP_DIR exists but is not readable by unprivileged users; delete it once the new backups are proven"
fi
kf="$KUMA_STORAGE_FILE"   # v3.1: was a one-item loop (ShellCheck SC2066)
  [[ "$(stat -c '%a %U' "$kf" 2>/dev/null)" == "600 root" ]] && finding PASS "storage-monitor push URL stored root-only (600)" || finding WARN "storage push URL file missing or not 600 root"
crontab -l 2>/dev/null | grep -v '^\s*#' | grep -q 'storage-watchdog' \
  && finding PASS "root crontab runs the storage watchdog" || finding WARN "the storage watchdog is NOT scheduled in root's crontab"
[[ -z "$(ls -A /var/backups/homelab-stage 2>/dev/null)" ]] \
  && finding PASS "no leftover staging data" || finding WARN "leftover staging data in /var/backups/homelab-stage (contains secrets)"

# ---------------------------------------------------------------- 12
section "Uptime Kuma monitors (read-only; no tokens or URLs printed)"
if have sqlite3 && [[ -r $KUMA_DB ]]; then
  echo "id|name|type|interval_s|retries|resend|active|last_status(1=up,0=down)|last_beat_utc|down_beats_24h"
  sqlite3 -readonly -separator '|' "$KUMA_DB" "
    SELECT m.id, m.name, m.type, m.\"interval\", m.maxretries, m.resend_interval, m.active,
      (SELECT status FROM heartbeat h WHERE h.monitor_id=m.id ORDER BY time DESC LIMIT 1),
      (SELECT time   FROM heartbeat h WHERE h.monitor_id=m.id ORDER BY time DESC LIMIT 1),
      (SELECT count(*) FROM heartbeat h WHERE h.monitor_id=m.id AND h.status=0 AND h.time > datetime('now','-1 day'))
    FROM monitor m ORDER BY m.id;" 2>&1
  echo
  n_mon=$(sqlite3 -readonly "$KUMA_DB" "SELECT count(*) FROM monitor WHERE active=1;" 2>/dev/null)
  n_dn=$(sqlite3 -readonly "$KUMA_DB" "SELECT count(*) FROM monitor m WHERE m.active=1 AND (SELECT status FROM heartbeat h WHERE h.monitor_id=m.id ORDER BY time DESC LIMIT 1)=0;" 2>/dev/null)
  n_r0=$(sqlite3 -readonly "$KUMA_DB" "SELECT count(*) FROM monitor WHERE active=1 AND maxretries=0;" 2>/dev/null)
  n_short=$(sqlite3 -readonly "$KUMA_DB" "SELECT count(*) FROM monitor WHERE active=1 AND type='push' AND name LIKE '%backup%' AND \"interval\" < 86400;" 2>/dev/null)
  [[ $n_mon =~ ^[0-9]+$ ]] && finding INFO "Uptime Kuma: $n_mon active monitor(s), $n_dn currently down"
  [[ $n_dn =~ ^[1-9] ]] && finding WARN "Uptime Kuma: $n_dn monitor(s) currently DOWN (see section 12)"
  [[ $n_r0 =~ ^[1-9] ]] && finding INFO "Uptime Kuma: $n_r0 active monitor(s) have 0 retries (a single failed check alerts immediately)"
  [[ $n_short =~ ^[1-9] ]] && finding WARN "Uptime Kuma: the backup push monitor interval is under 24 h (it will go red between nightly runs)"
else
  echo "(sqlite3 missing or $KUMA_DB unreadable)"; finding INFO "Uptime Kuma database could not be read for the monitor summary"
fi

# ---------------------------------------------------------------- 13
section "SCORECARD"
for lvl in FAIL WARN INFO PASS; do
  n=0; for f in "${FINDINGS[@]}"; do [[ ${f%%|*} == "$lvl" ]] && n=$((n+1)); done
  printf '%s: %d\n' "$lvl" "$n"
done
echo
for lvl in FAIL WARN INFO PASS; do
  for f in "${FINDINGS[@]}"; do [[ ${f%%|*} == "$lvl" ]] && printf '[%s] %s\n' "$lvl" "${f#*|}"; done
done

# ---- terminal summary (fd 3) ----
{
  echo
  echo "================ SCORECARD ================"
  for lvl in FAIL WARN; do
    for f in "${FINDINGS[@]}"; do [[ ${f%%|*} == "$lvl" ]] && printf '[%s] %s\n' "$lvl" "${f#*|}"; done
  done
  nf=0; nw=0; ni=0; np=0
  for f in "${FINDINGS[@]}"; do case ${f%%|*} in FAIL) nf=$((nf+1));; WARN) nw=$((nw+1));; INFO) ni=$((ni+1));; PASS) np=$((np+1));; esac; done
  echo "-------------------------------------------"
  echo "FAIL=$nf  WARN=$nw  INFO=$ni  PASS=$np"
  echo "Full report: $OUT"
  echo "Review it for anything personal, then attach it to the chat."
} >&3
