# Spark Monitor

A tiny native macOS menu bar app that shows what's running on a remote Linux host
and opens its web UIs in one click. Built for the [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/),
but it works against any SSH-reachable box.

It **auto-scans** — point it at a host and it discovers services with zero setup
on the remote: over SSH it lists listening TCP ports, probes which speak HTTP, and
shows them grouped, with clickable ↗ rows that open the web UIs in your browser.
The menu bar icon is a monochrome bolt that adapts to light/dark.

```
┌──────────────────────────────┐
│ ⚡ Spark Monitor        ● online  │   header: host + reachability pill
│   nvidia-dgx-spark            │
├──────────────────────────────┤
│ APPS                          │   section headers in NVIDIA green
│  ● Open WebUI       :8080  ↗  │
│  ● DGX Dashboard    :11000 ↗  │
│ MODELS                        │
│  ● vllm             :8011     │
│  ● litellm          :8000  ↗  │
│ DATA                          │
│  ● postgres         :5432     │
├──────────────────────────────┤
│ Updated 14:21:03  ↻ Refresh  ⏻ Quit │
└──────────────────────────────┘
```

Green ● = listening, red ○ = down. Built with SwiftUI in an `NSPopover`.

## Requirements
- macOS 13+ and the Xcode command line tools: `xcode-select --install`
- Passwordless SSH to the target host. Verify it works non-interactively:
  ```bash
  ssh <your-host> 'ss -tlnpH | head'
  ```

## Install
Build a `SparkMonitor.app` bundle and drop it in `/Applications`:
```bash
SPARK_HOST=<your-host> ./make-app.sh --install   # builds, installs, launches
```
`make-app.sh` with no flag just builds `SparkMonitor.app` in this folder to drag into
`/Applications` yourself. It's a menu-bar-only app (`LSUIElement`, no Dock icon).
Built locally it isn't quarantined; if Gatekeeper objects, right-click > Open once.

- **Start at login:** System Settings > General > Login Items > **+** > `SparkMonitor.app`.
- **After changes:** re-run `./make-app.sh --install` (quits the running copy and relaunches).
- **Quick try without installing:** `swift build -c release && .build/release/SparkMonitor`
  (runs in the menu bar but stops when the terminal closes).

## Configuration (environment variables)
| Var | Default | Purpose |
|-----|---------|---------|
| `SPARK_HOST` | `nvidia-dgx-spark` | SSH host/alias to poll |
| `SPARK_HTTP_HOST` | = `SPARK_HOST` | host used to build openable URLs |
| `SPARK_PORTS_CMD` | *(unset = auto-scan)* | override with your own remote command (see below) |
| `SPARK_POLL_SECS` | `15` | poll interval |

Set these in the app's `Info.plist` `LSEnvironment`, or the `launchd` plist's
`EnvironmentVariables`, to make them persistent.

## How auto-scan works / using your own source
With `SPARK_PORTS_CMD` unset, the app pipes [`scan-ports.sh`](scan-ports.sh) to the
host via `ssh host bash -s` (nothing is installed remotely) and renders its JSON.
To use a curated list instead — your own names, groups, and URLs — set
`SPARK_PORTS_CMD` to any command on the host that prints the same JSON array:

```json
[{"port":8080,"service":"Open WebUI","group":"ui","notes":"","up":true,"cmd":"","path":"/"}]
```
- `group`: one of `ui` `inference` `mcp` `orchestration` `tools` `data` `service` (drives the section + order)
- `path`: `/` (or any path) makes the row clickable/openable; empty = info-only
- `up`: `false` renders a dimmed red-dot row

## Snappier polling (optional)
Each poll opens a fresh SSH connection. To make it instant, enable connection
multiplexing in `~/.ssh/config`:
```
Host nvidia-dgx-spark
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

## License
MIT — see [LICENSE](LICENSE).
