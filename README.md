# Spark Monitor

A macOS menu bar app that shows what's running on a remote Linux box over SSH
and opens its web UIs in your browser. Made for the NVIDIA DGX Spark. Works
against any SSH-reachable host.

```
┌────────────────────────────────────────┐
│ ⚡ Spark Monitor              ● online │
│   nvidia-dgx-spark                     │
├────────────────────────────────────────┤
│  All  Apps  Models  MCP  Tools  Data   │
├────────────────────────────────────────┤
│ APPS                                   │
│ ▏ 🪟  Open WebUI          8080    ↗   │
│ ▏ 🔲  DGX Dashboard      11000    ↗   │
│ MODELS                                 │
│ ▏ 💻  vLLM · smart        8011        │
│ ▏ 🔀  LiteLLM             8000    ↗   │
│ MCP                                    │
│ ▏ 🧩  MCP · fetch         9001    ↗   │
│ ▏ 🧩  MCP · filesystem    9002    ↗   │
│ DATA                                   │
│ ▏ 🗄   PostgreSQL          5432        │
├────────────────────────────────────────┤
│ Updated 14:21:03            ↻ Refresh  │
└────────────────────────────────────────┘
```

Services are grouped by kind. A tab bar at the top lets you filter to one
group. Rows with `↗` open in your browser. Right-click any row to copy its
URL or port number. The left accent bar is colour-coded: blue for apps,
green for inference models, purple for MCP, orange for agents, teal for
tools, and light blue for data services.

Nothing is installed on the remote host. The app pipes a self-contained
bash script over SSH, which lists listening TCP ports, fingerprints each
HTTP service (HTML title, OpenAI `/v1/models`, Ollama `/api/tags`), reads
`/proc/PID/cmdline` for process names, and queries Docker for container
names. The whole scan takes about two seconds.

## Setup

Requirements:

- macOS 13 or later
- Xcode command line tools: `xcode-select --install`
- **Key-based (passwordless) SSH to the host.** The app cannot type a
  password for you. `ssh your-host hostname` must work without prompting.
  If it asks for a password, run `ssh-copy-id user@your-host` first
  (after `ssh-keygen -t ed25519` if you don't already have a key).

Then:

```bash
git clone https://github.com/your-user/spark-monitor.git
cd spark-monitor
./setup.sh
```

`setup.sh` asks for your SSH host, builds the app, installs it to
`/Applications`, and registers it as a login item. The first build is slow
because Swift downloads its toolchain.

To change the host later, run `./setup.sh` again.

## Configuration

The app reads these environment variables from its `Info.plist`:

| Var | Default | Purpose |
|---|---|---|
| `SPARK_HOST` | `nvidia-dgx-spark` | SSH host or alias |
| `SPARK_HTTP_HOST` | same as `SPARK_HOST` | host used when building clickable URLs |
| `SPARK_PORTS_CMD` | unset (auto-scan) | override: remote command that prints services as JSON |
| `SPARK_POLL_SECS` | `15` | poll interval, seconds |

Re-running `setup.sh` rewrites `SPARK_HOST`. For the others, edit
`LSEnvironment` in `/Applications/SparkMonitor.app/Contents/Info.plist` and
relaunch the app.

## Custom scanner (escape hatch)

The built-in scanner works without any configuration. If you want to add
services that don't listen on TCP (e.g. a VPN-only endpoint) or override
a name, set `SPARK_PORTS_CMD` to any command on the host that prints this
JSON shape:

```json
[
  {"port": 8080, "service": "Open WebUI", "group": "ui",        "notes": "", "up": true, "cmd": "", "path": "/"},
  {"port": 8011, "service": "vLLM smart", "group": "inference", "notes": "80B model", "up": true, "cmd": "", "path": ""}
]
```

`group` is one of `ui`, `inference`, `mcp`, `orchestration`, `tools`,
`data`, `service`. A non-empty `path` makes the row clickable.

See `signatures.json` in the repo for the full list of services the
built-in scanner already recognises.

## Faster polling

Each refresh opens a fresh SSH connection. To keep one open in the
background, add to `~/.ssh/config`:

```
Host your-host
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

## launchd alternative

`setup.sh` registers the app as a macOS Login Item, which is enough for
most people. If you prefer launchd, copy
`launchd/com.sparkmonitor.agent.plist` to `~/Library/LaunchAgents/` and
load it:

```bash
cp launchd/com.sparkmonitor.agent.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.sparkmonitor.agent.plist
```

## License

MIT.
