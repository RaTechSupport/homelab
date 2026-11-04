# Scripts

Version-controlled copies of the tooling that runs JARVIS. They are written for this one server (paths like `/mnt/6TB_Storage`, container names, a Core 2 Duo's limits), so read them as worked examples rather than a turnkey product. All bash scripts pass ShellCheck in CI.

| Script | Installed as | Runs | What it does |
|---|---|---|---|
| `homelab-backup.sh` | `/usr/local/sbin/` | root cron 07:00 UTC | Nightly full backup: stops monitoring first and Plex/Nextcloud for ~1 minute, SQLite online backups, host settings, system inventory; `gzip -t`, coverage check, SHA-256, keep 14; heartbeat to Uptime Kuma |
| `backup-mirror.sh` | `/usr/local/sbin/` | root cron 07:30 UTC | 3-2-1 mirror: waits on the backup lock, copies the newest archive to the internal SSD (verified, keep 14), encrypts it with `age` (public key only) into the SFTP outbox (keep 2) |
| `sshd-backuppull.conf` | `/etc/ssh/sshd_config.d/` | sshd | Locked-down pull account: chroot, `ForceCommand internal-sftp -R` (read-only), key only, no TTY/forwarding |
| `windows/Pull-JarvisBackup.ps1` | admin PC | Task Scheduler daily + at logon | Pulls the encrypted archive over SFTP, checks SHA-256, moves it into Google Drive's sync folder (keep 7), heartbeat to Uptime Kuma |
| `windows/Register-JarvisBackupTask.ps1` | admin PC | once | Creates the scheduled task above |
| `update-ub` | `/usr/local/bin/` | root cron Sundays 06:00 UTC | Weekly maintenance: non-interactive full upgrade keeping local config, image prune, report (upgraded/held/Docker restarted/reboot needed), container check, heartbeat; shares the backup's lock |
| `jarvis-status` | `/usr/local/bin/` | on demand | 10-second health check (~38 checks, OK/WARN/FAIL, exit 0/1/2): host, storage, the whole backup chain, containers, DNS (cached, uncached, blocking, DNSSEC), DHCP, services, Kuma's view, statistics collector, updates |
| `jarvis-audit.sh` | `/usr/local/sbin/` | on demand (the only sudo command of the automation account) | Read-only security audit and scorecard: users/keys/sudoers, effective sshd settings per account, firewall, exposure, secret file permissions, containers, updates |
| `dhcp-watchdog.sh` | `/usr/local/sbin/` | root cron every 5 min | Checks that Pi-hole's DHCP server is active; heartbeat to Uptime Kuma |
| `dns-watchdog.sh` | `/usr/local/sbin/` | root cron every minute | Resolves a random, never-cached name through Pi-hole -> Unbound; heartbeat with the answer time |
| `jarvis-netstats` | `/usr/local/sbin/` | root cron hourly | Long-term DNS / ad-blocking / DHCP statistics as CSV (per day, hour and client; top blocked/allowed domains; every device ever leased, with vendor); backfills from Pi-hole's database; `--report` for a quick look |
| `jarvis-iplist` | `/usr/local/bin/` | on demand | The home network at a glance: ping sweep + neighbour table + Pi-hole leases, manufacturer from the IEEE OUI list, best-guess device type |
| `jarvis-commands` | `/usr/local/bin/` | on demand | Lists every custom command with version, description and real cron schedule, discovered from a header convention |
| `portainer-run.sh` | (recipe) | by hand | How to recreate Portainer, which runs outside Compose |
| `logrotate-jarvis-update`, `logrotate-jarvis-ops` | `/etc/logrotate.d/` | logrotate | Rotation for the scripts' logs |

Conventions: every script starts with `# <name> [vX.Y] - <description>` (that is how `jarvis-commands` finds it), checks are read-only unless the name says otherwise, secrets (heartbeat URLs, keys) live in root-only files outside the scripts, and every change is installed with its SHA-256 recorded in the change log.
