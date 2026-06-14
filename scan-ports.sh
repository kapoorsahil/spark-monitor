#!/usr/bin/env bash
# Auto-scanner for SparkMonitor. The app pipes this over SSH:
#   ssh host bash -s < scan-ports.sh
# Discovers listening TCP ports, fingerprints each HTTP service by its
# HTML title or a known API endpoint, and prints JSON.
#
# Output shape, one object per service:
#   {"port":int,"service":str,"group":str,"notes":str,"up":bool,"cmd":str,"path":str}
#   group: ui | inference | data | mcp | orchestration | tools | service
#   path:  "/" when HTTP was detected and reachable, else ""

PROBE_TIMEOUT="${SPARK_PROBE_TIMEOUT:-1.5}"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Listening TCP ports. Extracts port, short process name, bind accessibility, PID.
rows=$(ss -tlnpH 2>/dev/null | awk '{
  split($4, a, ":"); p = a[length(a)];
  addr = $4; sub(/:[^:]+$/, "", addr);
  net = (addr == "127.0.0.1" || addr == "[::1]") ? 0 : 1;
  c = ""; if (match($0, /users:\(\("[^"]+"/)) c = substr($0, RSTART+9, RLENGTH-10);
  pid = ""; if (match($0, /pid=[0-9]+/)) pid = substr($0, RSTART+4, RLENGTH-4);
  printf "%s|%s|%s|%s\n", p, c, net, pid
}' | awk -F'|' '$1+0 >= 1 && $1+0 < 32768 && !seen[$1]++ &&
    $1 != 22 && $1 != 25 && $1 != 53 && $1 != 631 && $1 != 5353' \
  | sort -t'|' -k1,1n)

[ -z "$rows" ] && { echo '[]'; exit 0; }

tmp=$(mktemp -d)

# Build docker port→container map (runs once, synchronously before HTTP probes).
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # Explicit host port bindings from docker ps
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | \
    awk -F'\t' '{
      name=$1; ports=$2;
      while (match(ports, /[0-9]+->[0-9]+/)) {
        chunk = substr(ports, RSTART, RLENGTH); ports = substr(ports, RSTART+RLENGTH);
        split(chunk, a, "->"); split(a[1], b, ":"); print b[length(b)], name
      }
    }' > "$tmp/docker_ports"
  # Host-network containers: find --port N in their command
  docker ps --filter "network=host" --format '{{.Names}}' 2>/dev/null | \
    while read -r cname; do
      cmd=$(docker inspect --format '{{join .Config.Cmd " "}}' "$cname" 2>/dev/null)
      port=$(printf '%s' "$cmd" | grep -oE -- '--port [0-9]+' | grep -oE '[0-9]+$' | head -1)
      [ -n "$port" ] && printf '%s %s\n' "$port" "$cname"
    done >> "$tmp/docker_ports"
fi

# Format a docker container name into a human label.
fmt_container() {
  local n="$1"
  case "$n" in
    mcpo-*)     printf 'MCP · %s' "${n#mcpo-}";;
    open-webui) printf 'Open WebUI';;
    searxng)    printf 'SearXNG';;
    *postgres*|*-pg|pg-*) printf 'PostgreSQL';;
    *mysql*)    printf 'MySQL';;
    *redis*)    printf 'Redis';;
    *mongo*)    printf 'MongoDB';;
    *)          printf '%s' "$n" | tr '-' ' ' | \
                  awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; print}';;
  esac
}

# Derive a name from /proc/PID/cmdline when HTTP fingerprinting fails.
name_from_cmdline() {
  local cl; cl=$(cat "$tmp/${1}.cmdline" 2>/dev/null) || return
  [ -z "$cl" ] && return
  # vLLM: use --served-model-name alias
  if printf '%s' "$cl" | grep -q 'vllm serve'; then
    local m; m=$(printf '%s' "$cl" | grep -oE -- '--served-model-name [^ ]+' | awk '{print $2; exit}')
    [ -n "$m" ] && printf 'vLLM · %s' "$m" || printf 'vLLM'
    return
  fi
  printf '%s' "$cl" | grep -q 'litellm'  && printf 'LiteLLM'  && return
  printf '%s' "$cl" | grep -q 'jupyter'  && printf 'Jupyter'  && return
  # Node/TS apps: directory of the main script, or cwd if script is in src/dist/etc
  if printf '%s' "$cl" | grep -qE '(^| )(node|/usr/bin/node) '; then
    local script; script=$(printf '%s' "$cl" | grep -oE '[^ ]+\.(js|ts)' | grep -v node_modules | head -1)
    if [ -n "$script" ]; then
      local dir; dir=$(basename "$(dirname "$script")")
      case "$dir" in .|bin|src|dist|lib|app) ;; *) printf '%s' "$dir" && return;; esac
    fi
    # Walk up the cwd, skipping generic directory names, to find the project root
    local cwd_path; cwd_path=$(cat "$tmp/${1}.cwd" 2>/dev/null)
    local d="$cwd_path"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      local b; b=$(basename "$d"); d=$(dirname "$d")
      case "$b" in ''|.|src|dist|lib|app|server|backend|frontend|services|ui|bin|build) ;;
        *) printf '%s' "$b" && return;;
      esac
    done
  fi
}

# Pre-write net files and cmdlines before parallel probing.
while IFS='|' read -r port cmd net pid; do
  printf '%s' "$net" > "$tmp/${port}.net"
  if [ -n "$pid" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null > "$tmp/${port}.cmdline"
    readlink "/proc/$pid/cwd" 2>/dev/null > "$tmp/${port}.cwd"
  fi
done <<< "$rows"

# Parallel HTTP probes: root body, /v1/models, /api/tags.
while IFS='|' read -r port cmd net pid; do
  (
    curl -s -m "$PROBE_TIMEOUT" "http://127.0.0.1:$port/" 2>/dev/null \
      | head -c 16384 > "$tmp/${port}.body"
    if [ -s "$tmp/${port}.body" ]; then
      printf '1' > "$tmp/${port}.http"
    else
      rm -f "$tmp/${port}.body"
    fi
    if [ -f "$tmp/${port}.http" ]; then
      models=$(curl -s -m 1 "http://127.0.0.1:$port/v1/models" 2>/dev/null)
      printf '%s' "$models" | grep -q '"object"[[:space:]]*:[[:space:]]*"list"' && \
        printf '%s' "$models" > "$tmp/${port}.vllm"
      tags=$(curl -s -m 1 "http://127.0.0.1:$port/api/tags" 2>/dev/null)
      printf '%s' "$tags" | grep -q '"models"' && \
        printf '%s' "$tags" > "$tmp/${port}.ollama"
    fi
  ) &
done <<< "$rows"
wait

extract_title() {
  sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/Ip' "$1" 2>/dev/null | head -1 | \
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

match_title() {
  local t="$1"
  case "$t" in
    *"Open WebUI"*)            echo "Open WebUI|ui|/";;
    *"AnythingLLM"*)           echo "AnythingLLM|ui|/";;
    *"Lobe Chat"*)             echo "Lobe Chat|ui|/";;
    *"Jan"*)                   echo "Jan|ui|/";;
    *"text-generation-webui"*) echo "oobabooga|ui|/";;
    *"LiteLLM"*)               echo "LiteLLM|inference|/";;
    *"LocalAI"*)               echo "LocalAI|inference|/";;
    *"Stable Diffusion"*)      echo "Stable Diffusion|ui|/";;
    *"ComfyUI"*)               echo "ComfyUI|ui|/";;
    *"InvokeAI"*)              echo "InvokeAI|ui|/";;
    *"Flowise"*)               echo "Flowise|orchestration|/";;
    *"LangFlow"*)              echo "LangFlow|orchestration|/";;
    *"n8n"*)                   echo "n8n|orchestration|/";;
    *"Dify"*)                  echo "Dify|orchestration|/";;
    *"JupyterLab"*)            echo "JupyterLab|data|/";;
    *"Jupyter"*)               echo "Jupyter|data|/";;
    *"Grafana"*)               echo "Grafana|data|/";;
    *"Prometheus"*)            echo "Prometheus|data|/";;
    *"Netdata"*)               echo "Netdata|data|/";;
    *"pgAdmin"*)               echo "pgAdmin|data|/";;
    *"Metabase"*)              echo "Metabase|data|/";;
    *"code-server"*)           echo "code-server|tools|/";;
    *"Gitea"*)                 echo "Gitea|tools|/";;
    *"Portainer"*)             echo "Portainer|tools|/";;
    *"Traefik"*)               echo "Traefik|tools|/";;
    *"SearXNG"*)               echo "SearXNG|tools|/";;
    *"Whoogle"*)               echo "Whoogle|tools|/";;
    *) echo "";;
  esac
}

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
while IFS='|' read -r port cmd net pid; do
  [ -z "$port" ] && continue

  http=0; [ -f "$tmp/${port}.http" ] && http=1
  network=1; [ -f "$tmp/${port}.net" ] && network=$(cat "$tmp/${port}.net")
  name=""; group=""; path=""; notes_override=""

  # 1. Docker container name (handles containers with no ss process info)
  if [ -f "$tmp/docker_ports" ]; then
    dname=$(awk -v p="$port" '$1==p{print $2; exit}' "$tmp/docker_ports")
    if [ -n "$dname" ]; then
      formatted=$(fmt_container "$dname")
      if [ -n "$formatted" ]; then
        name="$formatted"
        case "$dname" in
          mcpo-*) group="mcp";;
          open-webui|*webui*) group="ui";;
          searxng|whoogle) group="tools";;
          *postgres*|*pg*|*mysql*|*redis*|*mongo*) group="data";;
          *) group="service";;
        esac
      fi
    fi
  fi

  # 2. HTTP fingerprinting (overrides docker name if more specific)
  if [ "$http" = 1 ]; then
    if [ -f "$tmp/${port}.vllm" ]; then
      model_id=$(grep -o '"id":"[^"]*"' "$tmp/${port}.vllm" 2>/dev/null | head -1 | cut -d'"' -f4)
      name="${model_id:+vLLM · $model_id}"; name="${name:-vLLM}"
      group="inference"; path=""
    elif [ -f "$tmp/${port}.ollama" ]; then
      model_names=$(grep -o '"name":"[^"]*"' "$tmp/${port}.ollama" 2>/dev/null \
        | cut -d'"' -f4 | head -3 | paste -sd ',' - 2>/dev/null)
      name="Ollama"; group="inference"; path=""
      [ -n "$model_names" ] && notes_override="$model_names"
    elif [ -z "$name" ] && [ -f "$tmp/${port}.body" ]; then
      title=$(extract_title "$tmp/${port}.body")
      if [ -n "$title" ]; then
        sig=$(match_title "$title")
        if [ -n "$sig" ]; then
          name=$(printf '%s' "$sig" | cut -d'|' -f1)
          group=$(printf '%s' "$sig" | cut -d'|' -f2)
          path=$(printf '%s' "$sig" | cut -d'|' -f3)
        else
          name="$title"; group="ui"; path="/"
        fi
      fi
    fi
    # Any HTTP service that isn't a pure API (vLLM/Ollama) gets a clickable path,
    # whether it was named via docker, title match, or fallback.
    if ! [ -f "$tmp/${port}.vllm" ] && ! [ -f "$tmp/${port}.ollama" ]; then
      path="/"
    fi
    [ "$network" = 0 ] && path=""
  fi

  # 3. Cmdline-based name (for non-HTTP services or unnamed node apps)
  if [ -z "$name" ]; then
    cl_name=$(name_from_cmdline "$port")
    [ -n "$cl_name" ] && name="$cl_name"
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
