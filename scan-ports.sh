#!/usr/bin/env bash
# Generic auto-scanner for SparkMonitor. Run on the target host (the app pipes it over
# SSH: `ssh host bash -s < scan-ports.sh`), emits a JSON array the app renders.
#
# No configuration and no install needed: it lists listening TCP ports, probes
# which ones speak HTTP (those become clickable "open" rows), and labels each by
# its listening process. For curated names/groups, point the app's SPARK_PORTS_CMD
# at your own script that emits the same shape instead.
#
# JSON contract (one object per service):
#   {"port":int,"service":str,"group":str,"notes":str,"up":bool,"cmd":str,"path":str}
#   group  : ui | inference | data | mcp | service   (drives section + ordering)
#   path   : "/" when HTTP was detected (openable), else ""  (up is always true here)

PROBE_TIMEOUT="${SPARK_PROBE_TIMEOUT:-0.6}"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Listening TCP ports -> "port<TAB>process", de-duped, skip the ephemeral range
# and a few host-infra ports that aren't user services (ssh, dns, cups, mdns, smtp).
rows=$(ss -tlnpH 2>/dev/null | awk '{
  split($4, a, ":"); p = a[length(a)];
  c = ""; if (match($0, /users:\(\("[^"]+"/)) c = substr($0, RSTART+9, RLENGTH-10);
  print p "\t" c
}' | awk -F'\t' '$1+0 >= 1 && $1+0 < 32768 && !seen[$1]++ &&
    $1 != 22 && $1 != 25 && $1 != 53 && $1 != 631 && $1 != 5353' \
  | sort -t"$(printf '\t')" -k1,1n)

[ -z "$rows" ] && { echo '[]'; exit 0; }

# Parallel HTTP probe: any HTTP status (even 401/404) means it's a web service.
tmp=$(mktemp -d)
while IFS=$'\t' read -r port cmd; do
  ( code=$(curl -s -o /dev/null -m "$PROBE_TIMEOUT" -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)
    [ -n "$code" ] && [ "$code" != "000" ] && echo 1 > "$tmp/$port" ) &
done <<< "$rows"
wait

# Classify by port/process into the app's groups.
classify_group() {
  local port="$1" cmd="$2" http="$3"
  case "$port" in
    5432|3306|6379|27017|5984|9200|54329) echo data; return;;
    11434|8000|8001|8011|8012|8013|8014) echo inference; return;;
  esac
  case "$cmd" in
    postgres|mysqld|redis*|mongod) echo data; return;;
    ollama|vllm|*python*) echo inference; return;;
  esac
  [ "$http" = 1 ] && { echo ui; return; }
  echo service
}

printf '['
first=1
while IFS=$'\t' read -r port cmd; do
  [ -z "$port" ] && continue
  http=0; [ -f "$tmp/$port" ] && http=1
  name="${cmd:-port $port}"
  group=$(classify_group "$port" "$cmd" "$http")
  path=""; [ "$http" = 1 ] && path="/"
  notes=""; [ -n "$cmd" ] && notes="process: $cmd"
  [ $first -eq 1 ] && first=0 || printf ','
  printf '{"port":%s,"service":"%s","group":"%s","notes":"%s","up":true,"cmd":"%s","path":"%s"}' \
    "$port" "$(json_escape "$name")" "$group" "$(json_escape "$notes")" "$(json_escape "$cmd")" "$path"
done <<< "$rows"
printf ']\n'

rm -rf "$tmp"
