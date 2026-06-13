#!/usr/bin/env bash
# Auto-scanner for SparkMonitor. The app pipes this over SSH:
#   ssh host bash -s < scan-ports.sh
# Discovers listening TCP ports, fingerprints each HTTP service by its
# HTML title or a known API endpoint, and prints JSON.
#
# Output shape, one object per service:
#   {"port":int,"service":str,"group":str,"notes":str,"up":bool,"cmd":str,"path":str}
#   group: ui | inference | data | mcp | orchestration | tools | service
#   path:  "/" when HTTP was detected (clickable row), else ""

PROBE_TIMEOUT="${SPARK_PROBE_TIMEOUT:-1.5}"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Listening TCP ports -> "port<TAB>process", de-duped, skip ephemeral range
# and host-infra ports (ssh, dns, cups, mdns, smtp).
# Bind address (network-accessible vs localhost-only) is stored separately
# in $tmp/<port>.net (written before parallel probing starts).
rows=$(ss -tlnpH 2>/dev/null | awk '{
  split($4, a, ":"); p = a[length(a)];
  addr = $4; sub(/:[^:]+$/, "", addr);
  net = (addr == "127.0.0.1" || addr == "[::1]") ? 0 : 1;
  c = ""; if (match($0, /users:\(\("[^"]+"/)) c = substr($0, RSTART+9, RLENGTH-10);
  printf "%s|%s|%s\n", p, c, net
}' | awk -F'|' '$1+0 >= 1 && $1+0 < 32768 && !seen[$1]++ &&
    $1 != 22 && $1 != 25 && $1 != 53 && $1 != 631 && $1 != 5353' \
  | sort -t'|' -k1,1n)

[ -z "$rows" ] && { echo '[]'; exit 0; }

tmp=$(mktemp -d)

# Pre-write net (bind accessibility) files before parallel probing.
# Keeps rows as 2 fields (port<TAB>cmd) to avoid awk empty-field collapsing.
while IFS='|' read -r port cmd net; do
  printf '%s' "$net" > "$tmp/${port}.net"
done <<< "$rows"

# For each port: probe HTTP, grab first 16KB of body, try /v1/models and /api/tags.
while IFS='|' read -r port cmd net; do
  (
    # Pipe through head to cap at 16KB - avoids --max-filesize exit code issues.
    curl -s -m "$PROBE_TIMEOUT" "http://127.0.0.1:$port/" 2>/dev/null \
      | head -c 16384 > "$tmp/${port}.body"
    # Non-empty file means HTTP responded.
    if [ -s "$tmp/${port}.body" ]; then
      printf '1' > "$tmp/${port}.http"
    else
      rm -f "$tmp/${port}.body"
    fi

    if [ -f "$tmp/${port}.http" ]; then
      # OpenAI-compat: /v1/models
      models=$(curl -s -m 1 "http://127.0.0.1:$port/v1/models" 2>/dev/null)
      if printf '%s' "$models" | grep -q '"object"[[:space:]]*:[[:space:]]*"list"'; then
        printf '%s' "$models" > "$tmp/${port}.vllm"
      fi
      # Ollama: /api/tags
      tags=$(curl -s -m 1 "http://127.0.0.1:$port/api/tags" 2>/dev/null)
      if printf '%s' "$tags" | grep -q '"models"'; then
        printf '%s' "$tags" > "$tmp/${port}.ollama"
      fi
    fi
  ) &
done <<< "$rows"
wait

# Extract HTML title from body.
extract_title() {
  sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/Ip' "$1" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Match a title string against known signatures.
# Prints "name|group|path" or empty string.
match_title() {
  local t="$1"
  case "$t" in
    *"Open WebUI"*)           echo "Open WebUI|ui|/";;
    *"AnythingLLM"*)          echo "AnythingLLM|ui|/";;
    *"Lobe Chat"*)            echo "Lobe Chat|ui|/";;
    *"Jan"*)                  echo "Jan|ui|/";;
    *"text-generation-webui"*) echo "oobabooga|ui|/";;
    *"LiteLLM"*)              echo "LiteLLM|inference|/";;
    *"LocalAI"*)              echo "LocalAI|inference|/";;
    *"Stable Diffusion"*)     echo "Stable Diffusion|ui|/";;
    *"ComfyUI"*)              echo "ComfyUI|ui|/";;
    *"InvokeAI"*)             echo "InvokeAI|ui|/";;
    *"Flowise"*)              echo "Flowise|orchestration|/";;
    *"LangFlow"*)             echo "LangFlow|orchestration|/";;
    *"n8n"*)                  echo "n8n|orchestration|/";;
    *"Dify"*)                 echo "Dify|orchestration|/";;
    *"JupyterLab"*)           echo "JupyterLab|data|/";;
    *"Jupyter"*)              echo "Jupyter|data|/";;
    *"Grafana"*)              echo "Grafana|data|/";;
    *"Prometheus"*)           echo "Prometheus|data|/";;
    *"Netdata"*)              echo "Netdata|data|/";;
    *"pgAdmin"*)              echo "pgAdmin|data|/";;
    *"Metabase"*)             echo "Metabase|data|/";;
    *"code-server"*)          echo "code-server|tools|/";;
    *"Gitea"*)                echo "Gitea|tools|/";;
    *"Portainer"*)            echo "Portainer|tools|/";;
    *"Traefik"*)              echo "Traefik|tools|/";;
    *"SearXNG"*)              echo "SearXNG|tools|/";;
    *"Whoogle"*)              echo "Whoogle|tools|/";;
    *) echo "";;
  esac
}

# Classify by port/process for ports that didn't fingerprint.
classify_group() {
  local port="$1" cmd="$2" http="$3"
  case "$port" in
    5432|3306|6379|27017|5984|9200) echo data; return;;
  esac
  case "$cmd" in
    postgres|mysqld|redis*|mongod) echo data; return;;
    ollama) echo inference; return;;
    *python*|*uvicorn*) echo inference; return;;
  esac
  [ "$http" = 1 ] && { echo ui; return; }
  echo service
}

printf '['
first=1
while IFS='|' read -r port cmd net; do
  [ -z "$port" ] && continue

  http=0; [ -f "$tmp/${port}.http" ] && http=1
  network=1; [ -f "$tmp/${port}.net" ] && network=$(cat "$tmp/${port}.net")
  name=""; group=""; path=""; notes_override=""

  if [ "$http" = 1 ]; then
    # 1. Try OpenAI-compat /v1/models
    if [ -f "$tmp/${port}.vllm" ]; then
      model_id=$(grep -o '"id":"[^"]*"' "$tmp/${port}.vllm" 2>/dev/null | head -1 | cut -d'"' -f4)
      name="${model_id:+vLLM ($model_id)}"; name="${name:-vLLM}"
      group="inference"; path=""
    # 2. Try Ollama /api/tags
    elif [ -f "$tmp/${port}.ollama" ]; then
      model_names=$(grep -o '"name":"[^"]*"' "$tmp/${port}.ollama" 2>/dev/null \
        | cut -d'"' -f4 | head -3 | paste -sd ',' - 2>/dev/null)
      name="Ollama"; group="inference"; path=""
      [ -n "$model_names" ] && notes_override="$model_names"
    # 3. Try HTML title
    elif [ -f "$tmp/${port}.body" ]; then
      title=$(extract_title "$tmp/${port}.body")
      if [ -n "$title" ]; then
        sig=$(match_title "$title")
        if [ -n "$sig" ]; then
          name=$(printf '%s' "$sig" | cut -d'|' -f1)
          group=$(printf '%s' "$sig" | cut -d'|' -f2)
          path=$(printf '%s' "$sig" | cut -d'|' -f3)
        else
          # Unknown title: use it verbatim
          name="$title"; group="ui"; path="/"
        fi
      fi
    fi
    # 4. Fall back to process name
    [ -z "$name" ] && path="/"
    # Localhost-only ports are not directly openable from the Mac
    [ "$network" = 0 ] && path=""
  fi

  [ -z "$name" ] && name="${cmd:-port $port}"
  [ -z "$group" ] && group=$(classify_group "$port" "$cmd" "$http")

  if [ -n "$notes_override" ]; then
    notes="$notes_override"
  else
    notes=""; [ -n "$cmd" ] && notes="process: $cmd"
  fi

  [ $first -eq 1 ] && first=0 || printf ','
  printf '{"port":%s,"service":"%s","group":"%s","notes":"%s","up":true,"cmd":"%s","path":"%s"}' \
    "$port" "$(json_escape "$name")" "$group" "$(json_escape "$notes")" "$(json_escape "$cmd")" "$path"
done <<< "$rows"
printf ']\n'

rm -rf "$tmp"
