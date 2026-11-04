#!/usr/bin/env bash
# dhcp-watchdog.sh - root cron every 5 min: report Pi-hole DHCP health to an Uptime Kuma push monitor.
# Healthy = pihole + dhcphelper running and Pi-hole's dhcp.active is true. Since 2026-10-25 Pi-hole is the
# network's DHCP server; if it fails, new devices get no address (emergency: AT&T DHCP On).
# Push URL: /root/.kuma_push_dhcp_url (600 root). Kuma monitor "Pi-hole DHCP" (push, 900 s, retries 1).
set -uo pipefail

URL_FILE=/root/.kuma_push_dhcp_url
[[ -r $URL_FILE ]] || exit 0
url="$(head -n1 "$URL_FILE")"
url="${url%%\?*}"

problems=()
[[ "$(docker inspect -f '{{.State.Running}}' pihole 2>/dev/null)" == true ]]     || problems+=("pihole not running")
[[ "$(docker inspect -f '{{.State.Running}}' dhcphelper 2>/dev/null)" == true ]] || problems+=("dhcphelper not running")
[[ "$(docker exec pihole pihole-FTL --config dhcp.active 2>/dev/null)" == true ]] || problems+=("Pi-hole dhcp.active is not true")

if (( ${#problems[@]} == 0 )); then
  status=up;   msg="OK leases=$(wc -l < /etc/pihole/dhcp.leases 2>/dev/null || echo 0)"
else
  status=down; msg="DHCP problem: ${problems[*]}"
fi
curl -fsS -m 15 --retry 3 --get --data-urlencode "status=$status" --data-urlencode "msg=$msg" "$url" >/dev/null 2>&1 || true
