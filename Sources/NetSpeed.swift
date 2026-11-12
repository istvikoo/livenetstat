import SwiftUI
import Darwin

// MARK: - Reading interface byte counters (sysctl NET_RT_IFLIST2)

struct Counters {
    var perInterface: [String: (rx: UInt64, tx: UInt64)] = [:]
    /// Interfaces that are up, running and have received data, in system order.
    var activeInterfaces: [String] = []
}

/// Delta between two counter readings.
/// macOS reports these counters truncated to 32 bits to unprivileged apps, so a decrease is
/// normally a wrap-around. A wrap that would mean more than 1 GB in one interval (~8.5 Gbit/s)
/// is not plausible and is treated as a counter reset (interface re-created) instead.
func counterDelta(_ new: UInt64, _ old: UInt64) -> UInt64 {
    if new >= old { return new - old }
    guard old < (1 << 32) else { return 0 }
    let wrapped = new + (1 << 32) - old
    return wrapped < (1 << 30) ? wrapped : 0
}

/// Returns nil if the kernel call fails (e.g. the interface list changed mid-read);
/// the caller then simply skips that sample.
func readCounters() -> Counters? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var needed = 0
    guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
    // Slack: the list may grow between the size query and the actual read.
    var len = needed + 2048
    let buf = UnsafeMutableRawPointer.allocate(byteCount: len, alignment: 8)
    defer { buf.deallocate() }
    guard sysctl(&mib, 6, buf, &len, nil, 0) == 0 else { return nil }

    let headerSize = MemoryLayout<if_msghdr2>.stride
    var result = Counters()
    var offset = 0
    // Every routing message starts with: u_short msglen, u_char version, u_char type.
    while offset + 4 <= len {
        let msgLen = Int(buf.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        guard msgLen > 0, offset + msgLen <= len else { break }
        defer { offset += msgLen }

        let type = Int32(buf.load(fromByteOffset: offset + 3, as: UInt8.self))
        guard type == RTM_IFINFO2, msgLen >= headerSize + 8 else { continue }
        // Messages are not guaranteed to be 8-byte aligned, so never bind the pointer directly.
        let ifm = buf.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
        guard ifm.ifm_flags & IFF_UP != 0, ifm.ifm_addrs & RTA_IFP != 0 else { continue }

        // The interface name sits in the sockaddr_dl right after the header:
        // [len][family][index:2][type][nlen][alen][slen][name bytes...]
        let sdl = offset + headerSize
        guard buf.load(fromByteOffset: sdl + 1, as: UInt8.self) == UInt8(AF_LINK) else { continue }
        let nameLen = Int(buf.load(fromByteOffset: sdl + 5, as: UInt8.self))
        guard nameLen > 0, sdl + 8 + nameLen <= offset + msgLen else { continue }
        let name = String(decoding: UnsafeRawBufferPointer(start: buf + sdl + 8, count: nameLen), as: UTF8.self)

        // Physical interfaces only: Wi-Fi/Ethernet (en*) and cellular (pdp_ip*).
        // Skip loopback, VPN tunnels (utun*), AWDL, bridges — avoids double counting.
        guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
        let rx = UInt64(ifm.ifm_data.ifi_ibytes), tx = UInt64(ifm.ifm_data.ifi_obytes)
        result.perInterface[name] = (rx, tx)
        if ifm.ifm_flags & IFF_RUNNING != 0, rx > 0 { result.activeInterfaces.append(name) }
    }
    return result
}

// MARK: - Formatting

enum UnitMode: String { case bytes, bits }

func formatRate(_ bytesPerSec: Double, mode: UnitMode) -> String {
    let units = mode == .bits ? ["b/s", "Kb/s", "Mb/s", "Gb/s"] : ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = mode == .bits ? bytesPerSec * 8 : bytesPerSec
    var i = 0
    // 999.5 rather than 1000 so rounding never prints "1000 KB/s".
    while i < units.count - 1 && value >= 999.5 { value /= 1000; i += 1 }
    return String(format: i >= 2 ? "%.1f %@" : "%.0f %@", value, units[i])
}

// MARK: - Monitor

@MainActor
final class Monitor: ObservableObject {
    static let historyLength = 60

    // Updated together; one objectWillChange per sample instead of one per property.
    private(set) var down: Double = 0
    private(set) var up: Double = 0
    private(set) var historyDown = [Double](repeating: 0, count: historyLength)
    private(set) var historyUp = [Double](repeating: 0, count: historyLength)
    private(set) var interfaces: [String] = []
    private(set) var hasSample = false

    @Published var mode: UnitMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "unitMode") }
    }

    private var last = Counters()
    private var lastTime: TimeInterval = 0   // monotonic, immune to wall-clock changes
    private var timer: Timer?

    init() {
        mode = UnitMode(rawValue: UserDefaults.standard.string(forKey: "unitMode") ?? "") ?? .bytes
    }

    /// Called when the panel opens. Takes a baseline and starts sampling once per second.
    func start() {
        guard timer == nil else { return }
        objectWillChange.send()
        down = 0; up = 0; hasSample = false
        historyDown = [Double](repeating: 0, count: Self.historyLength)
        historyUp = [Double](repeating: 0, count: Self.historyLength)
        last = readCounters() ?? Counters()
        lastTime = ProcessInfo.processInfo.systemUptime
        interfaces = last.activeInterfaces

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // Timers on the main run loop fire on the main thread.
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common) // keep ticking while the panel is being interacted with
        timer = t
    }

    /// Called when the panel closes. No work happens until the next open.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard timer != nil, let current = readCounters() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTime
        guard dt > 0.05 else { return }

        var dRx: UInt64 = 0, dTx: UInt64 = 0
        for (name, value) in current.perInterface {
            guard let prev = last.perInterface[name] else { continue } // new interface: counted from next tick
            dRx += counterDelta(value.rx, prev.rx)
            dTx += counterDelta(value.tx, prev.tx)
        }

        objectWillChange.send()
        down = Double(dRx) / dt
        up = Double(dTx) / dt
        hasSample = true
        historyDown.removeFirst(); historyDown.append(down)
        historyUp.removeFirst(); historyUp.append(up)
        interfaces = current.activeInterfaces
        last = current
        lastTime = now
    }
}

// MARK: - UI

struct Sparkline: Shape {
    let values: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1, maxValue > 0 else { return p }
        let inset: CGFloat = 1 // keeps the stroke inside the background at 0 and at the peak
        let height = rect.height - inset * 2
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let point = CGPoint(x: CGFloat(i) * step,
                                y: inset + height * (1 - CGFloat(min(v / maxValue, 1))))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        return p
    }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        // Graph scale: the highest value in the window, but never below 1 KB/s.
        let peak = max(monitor.historyDown.max() ?? 0, monitor.historyUp.max() ?? 0, 1000)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                stat("Download", "arrow.down", monitor.down, .blue)
                stat("Upload", "arrow.up", monitor.up, .orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08))
                    Sparkline(values: monitor.historyDown, maxValue: peak)
                        .stroke(Color.blue, lineWidth: 1.5)
                    Sparkline(values: monitor.historyUp, maxValue: peak)
                        .stroke(Color.orange, lineWidth: 1.5)
                }
                .frame(height: 70)
                HStack {
                    Text("Last 60 s")
                    Spacer()
                    Text("scale to \(formatRate(peak, mode: monitor.mode))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Interface").foregroundStyle(.secondary)
                Spacer()
                Text(monitor.interfaces.isEmpty ? "—" : monitor.interfaces.joined(separator: ", "))
            }
            .font(.caption)

            Picker("", selection: $monitor.mode) {
                Text("MB/s").tag(UnitMode.bytes)
                Text("Mb/s").tag(UnitMode.bits)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 280)
        // Sample only while the panel is on screen. onAppear/onDisappear are the primary signal;
        // the window notifications cover macOS versions where they don't fire on every open.
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            monitor.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            monitor.stop()
        }
    }

    private func stat(_ title: String, _ icon: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(color)
            Text(monitor.hasSample ? formatRate(value, mode: monitor.mode) : "…")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading) // fixed columns: no jumping as digits change
    }
}

@main
struct NetSpeedApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        // Only one copy at a time, otherwise two identical icons end up in the menu bar.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != getpid() }) {
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            // Static icon: nothing in the menu bar changes, so nothing needs updating in the background.
            Image(systemName: "arrow.up.arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
