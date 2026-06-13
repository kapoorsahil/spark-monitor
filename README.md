# Spark Monitor

A macOS menu bar app that shows what's running on a remote Linux box over SSH
and opens its web UIs in your browser. Made for the NVIDIA DGX Spark. Works
against any SSH-reachable host.

```
┌──────────────────────────────────┐
│ ⚡ Spark Monitor       ● online  │
│   nvidia-dgx-spark               │
├──────────────────────────────────┤
│ APPS                             │
│  ● Open WebUI       :8080    ↗   │
│  ● DGX Dashboard    :11000   ↗   │
│ MODELS                           │
│  ● vllm             :8011        │
│  ● litellm          :8000    ↗   │
│ DATA                             │
│  ● postgres         :5432        │
├──────────────────────────────────┤
│ Updated 14:21:03   ↻ Refresh  ⏻  │
└──────────────────────────────────┘
```

By default the app auto-detects services. It pipes a short script over SSH
(nothing is installed on the host), lists listening TCP ports, checks which
ones speak HTTP, and groups them by kind. Rows marked `↗` open in your
browser.

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
git clone https://github.com/kapoorsahil/spark-monitor.git
cd spark-monitor
./setup.sh
```

`setup.sh` asks for your host, builds the app, installs it to
`/Applications`, and adds it as a login item. The first build is slow
because Swift downloads its toolchain.

To change the host later, run `./setup.sh` again.

## Configuration

The app reads these environment variables from its `Info.plist`:

| Var | Default | Purpose |
|---|---|---|
| `SPARK_HOST` | `nvidia-dgx-spark` | SSH host or alias |
| `SPARK_HTTP_HOST` | same as `SPARK_HOST` | host used when building URLs |
| `SPARK_PORTS_CMD` | unset (auto-scan) | remote command that prints services as JSON |
| `SPARK_POLL_SECS` | `15` | poll interval, seconds |

Re-running `setup.sh` rewrites `SPARK_HOST`. For the others, edit
`LSEnvironment` in `/Applications/SparkMonitor.app/Contents/Info.plist` and
relaunch the app.

## Curating the list yourself

Auto-scan labels services by their process name (`vllm`, `node`, `postgres`)
and detects which ones serve a web UI. If you want nicer names and
grouping, set `SPARK_PORTS_CMD` to any command on the host that prints this
shape:

```json
[
  {"port": 8080, "service": "Open WebUI", "group": "ui",        "notes": "", "up": true, "cmd": "", "path": "/"},
  {"port": 8011, "service": "vLLM smart", "group": "inference", "notes": "80B model", "up": true, "cmd": "", "path": ""}
]
```

`group` is one of `ui`, `inference`, `mcp`, `orchestration`, `tools`,
`data`, `service`. A non-empty `path` makes the row clickable.

## Faster polling

Each refresh opens a fresh SSH connection. To keep one open in the
background, add to `~/.ssh/config`:

```
Host your-host
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

## License

MIT.
