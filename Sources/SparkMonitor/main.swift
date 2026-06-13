import SwiftUI
import AppKit
import Combine

// SparkMonitor: macOS menu bar status panel for a remote host. Made for the
// NVIDIA DGX Spark; works against any SSH-reachable Linux box.
//
// When SPARK_PORTS_CMD is unset, the app pipes scanScript (below) over
// `ssh host bash -s`. The script lists listening TCP ports, probes which
// speak HTTP, and emits JSON. Setting SPARK_PORTS_CMD overrides this with
// any remote command that prints the same JSON shape.
//
// Env vars:
//   SPARK_HOST       SSH host or alias. Default: nvidia-dgx-spark.
//   SPARK_PORTS_CMD  Remote command to run instead of the auto-scan.
//   SPARK_HTTP_HOST  Host used when building URLs. Default: same as SPARK_HOST.
//   SPARK_POLL_SECS  Poll interval in seconds. Default: 15.

struct Service: Codable, Identifiable {
    let port: Int
    let service: String
    let group: String
    let notes: String
    let up: Bool
    let cmd: String
    let path: String
    var id: Int { port }
    var openable: Bool { up && !path.isEmpty }
}

// Display order + human labels for the `group` field. The first set matches a
// curated ports.sh; "service" is the auto-scanner's catch-all and renders last.
let groupOrder: [(key: String, label: String)] = [
    ("ui", "Apps"),
    ("inference", "Models"),
    ("mcp", "MCP servers"),
    ("orchestration", "Orchestration"),
    ("tools", "Tools"),
    ("data", "Data"),
    ("service", "Other"),
]

// Scanner piped to the host when SPARK_PORTS_CMD is unset. Mirrors
// scan-ports.sh in the repo root; keep the two in sync.
let scanScript = #"""
PROBE_TIMEOUT="${SPARK_PROBE_TIMEOUT:-1.5}"
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
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
while IFS='|' read -r port cmd net; do
  printf '%s' "$net" > "$tmp/${port}.net"
done <<< "$rows"
while IFS='|' read -r port cmd net; do
  ( curl -s -m "$PROBE_TIMEOUT" "http://127.0.0.1:$port/" 2>/dev/null \
      | head -c 16384 > "$tmp/${port}.body"
    if [ -s "$tmp/${port}.body" ]; then
      printf '1' > "$tmp/${port}.http"
    else
      rm -f "$tmp/${port}.body"
    fi
    if [ -f "$tmp/${port}.http" ]; then
      models=$(curl -s -m 1 "http://127.0.0.1:$port/v1/models" 2>/dev/null)
      printf '%s' "$models" | grep -q '"object"[[:space:]]*:[[:space:]]*"list"' && printf '%s' "$models" > "$tmp/${port}.vllm"
      tags=$(curl -s -m 1 "http://127.0.0.1:$port/api/tags" 2>/dev/null)
      printf '%s' "$tags" | grep -q '"models"' && printf '%s' "$tags" > "$tmp/${port}.ollama"
    fi ) &
done <<< "$rows"
wait
extract_title() { sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/Ip' "$1" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
match_title() {
  local t="$1"
  case "$t" in
    *"Open WebUI"*) echo "Open WebUI|ui|/";; *"AnythingLLM"*) echo "AnythingLLM|ui|/";;
    *"Lobe Chat"*) echo "Lobe Chat|ui|/";; *"Jan"*) echo "Jan|ui|/";;
    *"text-generation-webui"*) echo "oobabooga|ui|/";; *"LiteLLM"*) echo "LiteLLM|inference|/";;
    *"LocalAI"*) echo "LocalAI|inference|/";; *"Stable Diffusion"*) echo "Stable Diffusion|ui|/";;
    *"ComfyUI"*) echo "ComfyUI|ui|/";; *"InvokeAI"*) echo "InvokeAI|ui|/";;
    *"Flowise"*) echo "Flowise|orchestration|/";; *"LangFlow"*) echo "LangFlow|orchestration|/";;
    *"n8n"*) echo "n8n|orchestration|/";; *"Dify"*) echo "Dify|orchestration|/";;
    *"JupyterLab"*) echo "JupyterLab|data|/";; *"Jupyter"*) echo "Jupyter|data|/";;
    *"Grafana"*) echo "Grafana|data|/";; *"Prometheus"*) echo "Prometheus|data|/";;
    *"Netdata"*) echo "Netdata|data|/";; *"pgAdmin"*) echo "pgAdmin|data|/";;
    *"Metabase"*) echo "Metabase|data|/";; *"code-server"*) echo "code-server|tools|/";;
    *"Gitea"*) echo "Gitea|tools|/";; *"Portainer"*) echo "Portainer|tools|/";;
    *"Traefik"*) echo "Traefik|tools|/";; *"SearXNG"*) echo "SearXNG|tools|/";;
    *"Whoogle"*) echo "Whoogle|tools|/";; *) echo "";;
  esac
}
classify_group() {
  local port="$1" cmd="$2" http="$3"
  case "$port" in 5432|3306|6379|27017|5984|9200) echo data; return;; esac
  case "$cmd" in postgres|mysqld|redis*|mongod) echo data; return;; ollama) echo inference; return;; *python*|*uvicorn*) echo inference; return;; esac
  [ "$http" = 1 ] && { echo ui; return; }; echo service
}
printf '['
first=1
while IFS='|' read -r port cmd net; do
  [ -z "$port" ] && continue
  http=0; [ -f "$tmp/${port}.http" ] && http=1
  network=1; [ -f "$tmp/${port}.net" ] && network=$(cat "$tmp/${port}.net")
  name=""; group=""; path=""; notes_override=""
  if [ "$http" = 1 ]; then
    if [ -f "$tmp/${port}.vllm" ]; then
      model_id=$(grep -o '"id":"[^"]*"' "$tmp/${port}.vllm" 2>/dev/null | head -1 | cut -d'"' -f4)
      name="${model_id:+vLLM ($model_id)}"; name="${name:-vLLM}"; group="inference"; path=""
    elif [ -f "$tmp/${port}.ollama" ]; then
      model_names=$(grep -o '"name":"[^"]*"' "$tmp/${port}.ollama" 2>/dev/null | cut -d'"' -f4 | head -3 | paste -sd ',' - 2>/dev/null)
      name="Ollama"; group="inference"; path=""
      [ -n "$model_names" ] && notes_override="$model_names"
    elif [ -f "$tmp/${port}.body" ]; then
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
    [ -z "$name" ] && path="/"
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
"""#

enum Theme {
    static let green = Color(red: 118/255, green: 185/255, blue: 0)
    static let red = Color(red: 0.886, green: 0.333, blue: 0.310)
    static let panel = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let rowHover = Color.white.opacity(0.06)
    static let divider = Color.white.opacity(0.10)
    static let textPrimary = Color(white: 0.92)
    static let textMuted = Color(white: 0.55)
}

func iconName(for svc: Service) -> String {
    let n = svc.service.lowercased()
    if n.contains("webui") { return "bubble.left.and.bubble.right" }
    if n.contains("dashboard") { return "gauge.with.dots.needle.50percent" }
    if n.contains("token") { return "chart.line.uptrend.xyaxis" }
    if n.contains("searxng") { return "magnifyingglass" }
    if n.contains("paperclip") { return "paperclip" }
    if n.contains("litellm") { return "arrow.triangle.branch" }
    if n.contains("openclaw") { return "network" }
    if n.contains("postgres") { return "cylinder.split.1x2" }
    switch svc.group {
    case "ui": return "macwindow"
    case "inference": return "cpu"
    case "mcp": return "puzzlepiece.extension"
    case "orchestration": return "point.3.connected.trianglepath.dotted"
    case "tools": return "wrench.and.screwdriver"
    case "data": return "internaldrive"
    default: return "circle"
    }
}

// MARK: - Data store

final class Store: ObservableObject {
    @Published var services: [Service] = []
    @Published var reachable = false
    @Published var fetching = false
    @Published var lastUpdate: Date?
    @Published var offlineSince: Date?

    let sshHost = ProcessInfo.processInfo.environment["SPARK_HOST"] ?? "nvidia-dgx-spark"
    let httpHost = ProcessInfo.processInfo.environment["SPARK_HTTP_HOST"]
        ?? ProcessInfo.processInfo.environment["SPARK_HOST"] ?? "nvidia-dgx-spark"
    let overrideCmd = ProcessInfo.processInfo.environment["SPARK_PORTS_CMD"]

    func refresh() {
        guard !fetching else { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (ok, list) = self.fetch()
            DispatchQueue.main.async {
                self.fetching = false
                self.reachable = ok
                if ok {
                    self.services = list
                    self.lastUpdate = Date()
                    self.offlineSince = nil
                } else if self.offlineSince == nil {
                    self.offlineSince = Date()
                }
            }
        }
    }

    private func fetch() -> (Bool, [Service]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let base = ["-o", "ConnectTimeout=4", "-o", "BatchMode=yes", sshHost]
        let autoScan = (overrideCmd == nil)
        proc.arguments = base + [autoScan ? "bash -s" : overrideCmd!]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        let inPipe = Pipe()
        if autoScan { proc.standardInput = inPipe }

        do { try proc.run() } catch { return (false, []) }
        if autoScan {
            inPipe.fileHandleForWriting.write(Data(scanScript.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let list = try? JSONDecoder().decode([Service].self, from: data) else {
            return (false, [])
        }
        return (true, list)
    }

    func open(_ svc: Service) {
        guard let url = URL(string: "http://\(httpHost):\(svc.port)\(svc.path)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Views

struct ServiceRow: View {
    let svc: Service
    let store: Store
    @State private var hovered = false

    var body: some View {
        let row = HStack(spacing: 10) {
            Circle().fill(svc.up ? Theme.green : Theme.red).frame(width: 7, height: 7)
            Image(systemName: iconName(for: svc))
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary.opacity(0.75))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(svc.service)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
                if !svc.notes.isEmpty && !svc.notes.hasPrefix("process:") {
                    Text(svc.notes)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Text(":\(svc.port)").font(.system(size: 11)).foregroundColor(Theme.textMuted)
            if svc.openable {
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundColor(Theme.green)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovered && svc.openable ? Theme.rowHover : Color.clear))
        .contentShape(Rectangle())
        .opacity(svc.up ? 1 : 0.5)
        .contextMenu {
            if svc.openable {
                Button("Open in Browser") { store.open(svc) }
                Divider()
                Button("Copy URL") {
                    let url = "http://\(store.httpHost):\(svc.port)\(svc.path)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
            Button("Copy :\(svc.port)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(svc.port)", forType: .string)
            }
        }

        if svc.openable {
            Button(action: { store.open(svc) }) { row }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
        } else {
            row
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @State private var collapsed: Set<String> = []

    var visibleGroups: [(key: String, label: String)] {
        groupOrder.filter { g in store.services.contains { $0.group == g.key } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            if store.reachable || !store.services.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !store.reachable, let since = store.offlineSince {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi.slash")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.red)
                                Text("Offline since \(timeStr(since))")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Theme.red.opacity(0.85))
                                Spacer()
                            }
                            .padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 2)
                        }
                        ForEach(visibleGroups, id: \.key) { g in
                            groupSection(g)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 460)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(Theme.red)
                    Text("Host unreachable: \(store.sshHost)")
                        .font(.system(size: 12)).foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
            Divider().overlay(Theme.divider)
            footer
        }
        .frame(width: 312)
        .background(Theme.panel)
    }

    @ViewBuilder
    func groupSection(_ g: (key: String, label: String)) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsed.contains(g.key) { collapsed.remove(g.key) }
                else { collapsed.insert(g.key) }
            }
        }) {
            HStack(spacing: 4) {
                Text(g.label.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(Theme.green)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.green.opacity(0.7))
                    .rotationEffect(.degrees(collapsed.contains(g.key) ? -90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: collapsed.contains(g.key))
            }
            .padding(.horizontal, 15).padding(.top, 11).padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if !collapsed.contains(g.key) {
            VStack(spacing: 0) {
                ForEach(store.services.filter { $0.group == g.key }) { svc in
                    ServiceRow(svc: svc, store: store)
                }
            }
            .padding(.horizontal, 7)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill").font(.system(size: 16)).foregroundColor(Theme.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Spark Monitor").font(.system(size: 14, weight: .medium)).foregroundColor(Theme.textPrimary)
                Text(store.sshHost).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(store.reachable ? Theme.green : Theme.red).frame(width: 6, height: 6)
                Text(store.reachable ? "online" : "offline").font(.system(size: 11))
                    .foregroundColor(store.reachable ? Theme.green : Theme.red)
            }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill((store.reachable ? Theme.green : Theme.red).opacity(0.14)))
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }

    var footer: some View {
        HStack(spacing: 14) {
            Text(stamp).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            Spacer()
            if store.fetching {
                ProgressView().scaleEffect(0.55).frame(width: 24, height: 16)
            } else {
                Button(action: { store.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(Theme.textMuted)
            }
            Button(action: { NSApp.terminate(nil) }) {
                Label("Quit", systemImage: "power").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 15).padding(.vertical, 9)
    }

    var stamp: String {
        guard let d = store.lastUpdate else { return "Updating…" }
        return "Updated \(timeStr(d))"
    }

    func timeStr(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let store = Store()
    var timer: Timer?
    var eventMonitor: Any?
    var cancellable: AnyCancellable?
    let pollSecs = Double(ProcessInfo.processInfo.environment["SPARK_POLL_SECS"] ?? "") ?? 15

    func applicationDidFinishLaunching(_ note: Notification) {
        let hosting = NSHostingController(rootView: PanelView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .applicationDefined
        popover.appearance = NSAppearance(named: .darkAqua)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Spark Monitor")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Update status bar icon when reachability changes.
        cancellable = store.$reachable.receive(on: RunLoop.main).sink { [weak self] reachable in
            guard let self else { return }
            let name = reachable ? "bolt.fill" : "bolt.slash"
            self.statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Spark Monitor")
            self.statusItem.button?.image?.isTemplate = true
        }

        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollSecs, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
