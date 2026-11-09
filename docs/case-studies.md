# Case studies

Real incidents and changes on JARVIS, Oct-Nov 2026. Each one: context, what happened, root cause, fix, and what changed so it cannot happen silently again. Addresses are left out on purpose.

---

## 1. DNS went down while switching DHCP to Pi-hole

**Context.** To get network-wide ad blocking, every device had to use Pi-hole for DNS. The ISP gateway cannot hand out a custom DNS server, so the plan was to move DHCP from the gateway to Pi-hole: a static IP for the server, static leases for known devices, a DHCP relay container (Pi-hole runs on a Docker bridge network, DHCP broadcasts do not cross it), firewall rules, then the cutover.

**What happened.** At the cutover (gateway DHCP off, Pi-hole DHCP on) Pi-hole's FTL engine restarted, logged `process is missing required capability NET_ADMIN` and **stopped serving DNS as well**: the whole network lost name resolution.

**Response.** Rolled back within minutes (Pi-hole DHCP off: DNS back immediately; gateway DHCP on). No lease had been issued yet, so no device was stranded. Total impact: about 10 minutes.

**Root cause.** The Pi-hole container lacked `cap_add: NET_ADMIN`, which its DHCP server needs (only the relay container had it). A DHCP configuration error makes FTL stop DNS too, so a DHCP-only change took down DNS.

**A second trap.** My first "it works" signal was wrong: the test phone showed the right DNS server only because its DNS was set *manually*. The test device must use automatic settings, and the proof is Pi-hole's own DHCP log (offer/ack), not one client's screen.

**Fix and prevention.** Added the capability, verified it in `docker inspect`, then redid the cutover with a DNS check and an automatic rollback ready. Added a DHCP heartbeat monitor (a watchdog checks every 5 minutes that Pi-hole's DHCP is active and pushes to Uptime Kuma) and a DHCP line in the health check. Kept a written emergency rollback: re-enable the gateway's DHCP.

**Lesson.** A change to one function of a multi-function service (DHCP) can break another (DNS). Rehearse the rollback, and verify with the system's own logs rather than a single client.

---

## 2. Monitoring was green while DNS was broken

**Context.** After tuning Unbound's caches (the record cache was at its tiny default while the message cache was large, wasting most of it), I applied the config with `docker restart unbound`.

**What happened.** Every lookup that was *not* in Pi-hole's cache timed out for about 20 minutes. Cached names still resolved, so my quick test and the existing monitors stayed green.

**Root cause.** Container IPs on a Docker network change on restart. Pi-hole resolves the upstream name `unbound` **once, at startup**, and kept sending queries to Unbound's old address. Diagnosed by querying Unbound directly on its new IP (it answered), then restarting Pi-hole.

**Why nothing alerted.** The Pi-hole monitor was an HTTP check of its web UI, and the health check resolved a well-known name that was always cached. Both tested the wrong thing.

**Fix and prevention.**
- Pinned Unbound (and Pi-hole) to fixed addresses on the Docker network and set Pi-hole's upstream **by IP**, so a restart or an automatic image update can no longer strand Pi-hole.
- New checks that measure what users feel: a lookup of a **random, never-cached name** (must go Pi-hole -> Unbound -> internet) in the health check and as a watchdog feeding an Uptime Kuma heartbeat every minute. A DNSSEC check (a deliberately mis-signed domain must be refused) runs alongside it.
- During the fix, a partial apply (only one of two edits saved) reproduced the outage for a few minutes, which the new check made obvious.

**Lesson.** "Up" is not "working". Monitor the user-visible path, and avoid name resolution that happens only at startup for critical dependencies.

---

## 3. Hardening Plex after a public exploit chain

**Context.** A remote-code-execution chain against Plex Media Server ("Plex2Shell") was being exploited in the wild, dropping cryptominers and proxies.

**Investigation (read-only first).**
- Version: already patched (the auto-update policy had kept it current).
- Indicators of compromise: no miner or proxy processes, CPU idle, only known Docker images, no unexpected plugin bundles, and the one outbound connection traced to Plex itself.
- Exposure: the router forwarded the Plex port, the host firewall allowed it from anywhere, and Plex's relay offered a second way in.

**Changes.** Removed the port forward and Plex Remote Access, disabled the relay, limited the firewall to LAN and VPN, mounted the media library **read-only** in the container, moved transcoding to the SSD, limited concurrent transcodes and lowered Plex's CPU priority so DNS and VPN stay responsive. Afterwards the router forwards exactly one port: WireGuard.

**Side effect, caught by monitoring.** Tightening the firewall broke the Plex monitor: the Signal alert arrived within minutes. The firewall log showed the blocked source: Uptime Kuma sits on two Docker networks and its traffic left through the *alerting* network, not the one I had allowed. One precise rule fixed it, and the recovery alert confirmed it.

**Lesson.** Patching closes one hole; removing exposure closes the class. And before changing a firewall rule or a password, list every client that depends on it (now a standing rule).

---

## 4. 3-2-1 backups without giving the server cloud credentials

**Context.** Nightly backups were verified and restore-tested, but lived on two disks in the same machine. The first off-site design (rclone to Google Drive from the server) stalled on API rate limits of a shared OAuth client and on OAuth tokens that expire weekly in testing mode.

**Design.**
- **Encrypt on the server with a public key** (`age`). The server only has the public key; the private key exists only in my password manager. A compromised server cannot decrypt old off-site copies, and the cloud only ever sees ciphertext.
- **Pull, don't push.** My PC fetches the encrypted file and drops it into Google Drive's sync folder. The server holds no cloud credentials at all.
- **A locked-down account for the pull:** a system user with no password and no shell, SSH key accepted only from the PC's address, chrooted to the outbox, `ForceCommand internal-sftp -R` (read-only SFTP), no TTY or forwarding. Tested from the PC: shell refused, port forwarding prohibited, uploads denied.
- **Ordering and integrity:** the mirror job shares the backup's lock, copies only finished archives (written as `.partial` until verified), checks SHA-256 at every hop, keeps 14 on the SSD, 2 in the outbox, 7 in the cloud.
- **Monitoring every stage:** the PC's pull reports to an Uptime Kuma heartbeat (alert if no successful copy in 3 days), and the health check confirms the newest archive is on the data drive, the SSD, the outbox and in the cloud.

**Restore test.** Downloaded the cloud copy, decrypted it with the key from the password manager and compared hashes. The **first attempt failed** ("unknown identity type"): the password manager's note had altered the comment line above the key. Only the key line itself is needed; the second attempt matched the original archive byte for byte. Without the test, that would have been discovered during a real disaster.

**Lesson.** An untested backup is a hope. Test the restore path end to end, including where the key is stored.

---

## 5. A major-version upgrade with a dry run: Uptime Kuma v1 to v2

**Context.** Uptime Kuma kept showing "update available", but automatic updates never delivered it. Research showed why: the project froze the `latest` tag on v1, because v2 converts the database on first start. Following `latest` would never upgrade; following a bare `2` tag gets 2.x updates automatically and makes a future v3 a deliberate, planned change.

**Plan.**
1. Full backup, plus a cold copy of the v1 data directory as the rollback.
2. **Dry run:** the v2 image against a SQLite backup copy of the live database, with `--network none` so it could not send alerts or touch production. The migration took about 4 minutes on this old CPU.
3. Change one line in the stack (`latest` -> `2`), let the migration run uninterrupted, then verify.

**A bug in my own tooling.** The first dry run reported "ready after 10 seconds". My readiness check matched the *temporary* migration web server's "Listening" line, not the real one. Fixed the check, reran: about 4 minutes. On a production run that mistake could have meant interrupting a migration that must not be interrupted.

**Verification.** All monitors active with fresh heartbeats, push monitors receiving, container healthy and now log-capped, a Signal test notification received, the dashboard widget correct. Planned monitoring gap: about 10 minutes.

**Lesson.** Rehearse irreversible migrations on a copy, isolate the rehearsal, and test your test.

---

## 6. Measure before buying: Wi-Fi backhaul and VPN capacity

**Context.** The server reaches the internet gateway over a wireless extender backhaul. A cable run was an option, and I wanted data before deciding.

**Measurements.**
- **Backhaul:** an Uptime Kuma ping monitor on the gateway, reviewed after a week (~12,000 checks): average 3-4.5 ms, but about one one-minute dropout per day, mostly in the evening. During each, the whole house loses DNS and DHCP from the server. One longer outage turned out to be a tripped breaker: the switch and extender went dark while the server ran on its battery, which exposed a second gap (no UPS for the network gear).
- **VPN load test:** speed tests from a phone over cellular through WireGuard while sampling CPU, temperature and memory every 2 seconds. Peak 254 Mbit/s at 25-33 % CPU (about 1 % CPU per 10 Mbit/s), temperatures +5 °C. The limit for several users is the Wi-Fi backhaul (VPN traffic crosses it twice), not the CPU.
- **Side finding:** regular 8-second I/O-wait spikes every 5 minutes, traced to Nextcloud's background job writing its SQLite database on the USB 2.0 drive. Harmless now; the fix (PostgreSQL on the SSD) is planned with the hardware migration.

**Outcome.** The data points to the cable, a small UPS for the network gear, and later an own router with queue management (a bufferbloat test scored C), rather than a faster server. An hourly collector now keeps DNS, ad-blocking and DHCP statistics as CSV files for the same kind of decisions about blocklists.

**Lesson.** Instrument first; let a week of data, not a hunch, decide where money goes.

---

## 7. A DNSSEC false positive: when "secure" quietly breaks streaming

**Context.** The resolver validates DNSSEC: an answer whose signatures don't check out is refused (SERVFAIL) instead of being passed on. The new hourly statistics showed one day with **239 failed lookups**, against 0-26 on every other day.

**Investigation.**
- **Drill-down** (one query against Pi-hole's database, by hour, domain and client): 234 of the 239 were **one name**, a Prime Video API endpoint, requested by **one smart TV** within **one hour**. Its app had retried for an hour. Every other domain resolved normally that day, so it was not an outage.
- **Live reproduction:** any *fresh* name under that Amazon subdomain still failed through my resolver. The same lookup with checking disabled (`dig +cd`) succeeded, which means my own validator was rejecting the answer.
- **Cross-check:** Cloudflare, Google and Quad9, which also validate DNSSEC, all answered normally.
- **Independent validation** with `delv +vtrace`: the whole chain is **unsigned** (no DS record for the domain), a five-step CNAME chain into a CDN with a 3-second TTL on one link. With nothing to validate, the correct verdict is "insecure", not "bogus".
- Once every link of the chain was cached separately, the name resolved, which explains why the problem only shows up now and then.

**Decision.** The fault is on my side: the validator mishandles this unusual (unsigned, multi-hop) chain; the exact reason wasn't logged at the time. I prepared a targeted fix: skip validation for that one domain only (`domain-insecure`; zero security cost, because the zone carries no signatures anyway) and turn on SERVFAIL reason logging so the next spike explains itself. Nobody had noticed a problem, so I chose to **monitor instead of changing a critical service**, with the diagnosis saved as ready-to-run queries and the fix documented.

**Lesson.** Security controls can fail closed in surprising ways. Compare against independent validators before blaming the network or the provider, keep the evidence reproducible, and change critical configuration when the benefit outweighs the risk, not just because a fix exists.
