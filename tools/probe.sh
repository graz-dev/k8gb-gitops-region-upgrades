#!/usr/bin/env bash
# One client-like probe: resolve the demo host through the edge DNS, then call
# the first address returned (what most clients do).
# Prints: <ips comma separated>|<http code>|<podinfo version>|<podinfo message>|<ms>
# Needs EDGEDNS_IP, EDGEDNS_PORT, HOSTNAME, GATEWAY_PORT in the environment.
ips=$(dig +short +tcp +time=2 +tries=1 @"$EDGEDNS_IP" -p "$EDGEDNS_PORT" "$HOSTNAME" A 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ',' | sed 's/,$//')
first=${ips%%,*}
if [ -z "$first" ]; then echo "|000|||0"; exit 0; fi
out=$(curl -s -m 2 -o /tmp/body.$$ -w '%{http_code} %{time_total}' -H "Host: $HOSTNAME" "http://$first:$GATEWAY_PORT/" 2>/dev/null || echo "000 0")
code=${out%% *}; secs=${out##* }
ver=""; msg=""
if [ "$code" = 200 ]; then ver=$(jq -r '.version // ""' /tmp/body.$$ 2>/dev/null); msg=$(jq -r '.message // ""' /tmp/body.$$ 2>/dev/null); fi
rm -f /tmp/body.$$
echo "$ips|$code|$ver|$msg|$(awk -v s="$secs" 'BEGIN{printf "%d", s*1000}')"
