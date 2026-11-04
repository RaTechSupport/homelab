#!/usr/bin/env bash
# dns-watchdog.sh - root cron every minute: report Pi-hole -> Unbound health to an Uptime Kuma push monitor.
# Looks up a random, never-cached name (chk<random>.example.com) via Pi-hole, so the answer has to come
# from Unbound. A fixed-name DNS monitor gets Pi-hole's cached (or stale) answer, which is how the
# 2026-10-26 outage (Pi-hole's upstream at an old Unbound IP) went unnoticed.
# Healthy = NOERROR or NXDOMAIN (2 tries, 3 s each). The lookup time is sent to Kuma as the ping value.
# Push URL: /root/.kuma_push_dns_url (600 root). Kuma monitor "DNS uncached" (push, 180 s, retries 2).
set -uo pipefail

URL_FILE=/root/.kuma_push_dns_url
[[ -r $URL_FILE ]] || exit 0
url="$(head -n1 "$URL_FILE")"
url="${url%%\?*}"

out="$(dig +time=3 +tries=2 @127.0.0.1 "chk${RANDOM}${RANDOM}.example.com" A 2>/dev/null)"
st="$(grep -oE 'status: [A-Z]+' <<<"$out" | cut -d' ' -f2)"
ms="$(grep -oE 'Query time: [0-9]+' <<<"$out" | grep -oE '[0-9]+$')"

case "$st" in
  NOERROR|NXDOMAIN) status=up;   msg="OK uncached lookup ${ms:-?} ms" ;;
  *)                status=down; msg="Uncached lookup failed (${st:-timeout}). Check: docker exec pihole pihole-FTL --config dns.upstreams (expect 172.22.0.54#53)" ;;
esac
args=(--data-urlencode "status=$status" --data-urlencode "msg=$msg")
[[ -n $ms ]] && args+=(--data-urlencode "ping=$ms")
curl -fsS -m 15 --retry 3 --get "${args[@]}" "$url" >/dev/null 2>&1 || true
