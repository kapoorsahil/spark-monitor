import SwiftUI
import AppKit

// SparkMonitor — a macOS menu bar status panel for a remote host (built for the NVIDIA
// DGX Spark, works against any SSH-reachable Linux box).
//
// By default it AUTO-SCANS: it pipes a small scanner (scanScript, below) to the
// host via `ssh host bash -s` — nothing is installed remotely — which lists
// listening TCP ports, probes which speak HTTP, and emits JSON. The panel shows
// what's up grouped by kind, with click-to-open for the web UIs.
//
// Config via environment (all optional):
//   SPARK_HOST       SSH host/alias (default: nvidia-dgx-spark)
//   SPARK_PORTS_CMD  override the auto-scan with your own remote command emitting the
//                  same JSON shape (e.g. a curated ports.sh) — unset = auto-scan
//   SPARK_HTTP_HOST  host used to build openable URLs (default: same as SPARK_HOST)
//   SPARK_POLL_SECS  poll interval in seconds (default: 15)

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

// Generic scanner piped to the host over `ssh host bash -s` when SPARK_PORTS_CMD is
// unset. Mirrors scan-ports.sh in the repo root — keep the two in sync.
let scanScript = #"""
PROBE_TIMEOUT="${SPARK_PROBE_TIMEOUT:-0.6}"
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
rows=$(ss -tlnpH 2>/dev/null | awk '{
  split($4, a, ":"); p = a[length(a)];
  c = ""; if (match($0, /users:\(\("[^"]+"/)) c = substr($0, RSTART+9, RLENGTH-10);
  print p "\t" c
}' | awk -F'\t' '$1+0 >= 1 && $1+0 < 32768 && !seen[$1]++ &&
    $1 != 22 && $1 != 25 && $1 != 53 && $1 != 631 && $1 != 5353' \
  | sort -t"$(printf '\t')" -k1,1n)
[ -z "$rows" ] && { echo '[]'; exit 0; }
tmp=$(mktemp -d)
while IFS=$'\t' read -r port cmd; do
  ( code=$(curl -s -o /dev/null -m "$PROBE_TIMEOUT" -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)
    [ -n "$code" ] && [ "$code" != "000" ] && echo 1 > "$tmp/$port" ) &
done <<< "$rows"
wait
classify_group() {
  case "$1" in 5432|3306|6379|27017|5984|9200|54329) echo data; return;; 11434|8000|8001|8011|8012|8013|8014) echo inference; return;; esac
  case "$2" in postgres|mysqld|redis*|mongod) echo data; return;; ollama|vllm|*python*) echo inference; return;; esac
  [ "$3" = 1 ] && { echo ui; return; }; echo service
}
printf '['
first=1
while IFS=$'\t' read -r port cmd; do
  [ -z "$port" ] && continue
  http=0; [ -f "$tmp/$port" ] && http=1
  name="${cmd:-port $port}"; group=$(classify_group "$port" "$cmd" "$http")
  path=""; [ "$http" = 1 ] && path="/"
  notes=""; [ -n "$cmd" ] && notes="process: $cmd"
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
    @Published var lastUpdate: Date?

    let sshHost = ProcessInfo.processInfo.environment["SPARK_HOST"] ?? "nvidia-dgx-spark"
    let httpHost = ProcessInfo.processInfo.environment["SPARK_HTTP_HOST"]
        ?? ProcessInfo.processInfo.environment["SPARK_HOST"] ?? "nvidia-dgx-spark"
    // nil => auto-scan (pipe scanScript over `bash -s`); set => run this verbatim.
    let overrideCmd = ProcessInfo.processInfo.environment["SPARK_PORTS_CMD"]

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (ok, list) = self.fetch()
            DispatchQueue.main.async {
                self.reachable = ok
                if ok { self.services = list; self.lastUpdate = Date() }
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
            Text(svc.service).font(.system(size: 13)).foregroundColor(Theme.textPrimary)
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
        .help(svc.notes)

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

    var visibleGroups: [(key: String, label: String)] {
        groupOrder.filter { g in store.services.contains { $0.group == g.key } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            if store.reachable {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleGroups, id: \.key) { g in
                            Text(g.label.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.6)
                                .foregroundColor(Theme.green)
                                .padding(.horizontal, 15).padding(.top, 11).padding(.bottom, 3)
                            VStack(spacing: 0) {
                                ForEach(store.services.filter { $0.group == g.key }) { svc in
                                    ServiceRow(svc: svc, store: store)
                                }
                            }
                            .padding(.horizontal, 7)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 460)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(Theme.red)
                    Text("Host unreachable — \(store.sshHost)")
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
            Button(action: { store.refresh() }) {
                Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(Theme.textMuted)
            Button(action: { NSApp.terminate(nil) }) {
                Label("Quit", systemImage: "power").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 15).padding(.vertical, 9)
    }

    var stamp: String {
        guard let d = store.lastUpdate else { return "Updating…" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "Updated \(f.string(from: d))"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let store = Store()
    var timer: Timer?
    let pollSecs = Double(ProcessInfo.processInfo.environment["SPARK_POLL_SECS"] ?? "") ?? 15

    func applicationDidFinishLaunching(_ note: Notification) {
        let hosting = NSHostingController(rootView: PanelView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Spark Monitor")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollSecs, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
