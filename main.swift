import Cocoa
import SwiftUI
import Darwin
import ServiceManagement

// ============================================================
//  MemBar — 菜单栏内存监控
//  数据来源全部走内核原始接口：
//    vm_statistics64 (host_statistics64) / sysctl vm.swapusage
//    kern.memorystatus_vm_pressure_level / proc_pid_rusage
//  注意：Apple Silicon 页大小 16KB，必须用 host_page_size() 读取
// ============================================================

let GB = 1_073_741_824.0
let MB = 1_048_576.0

func humanBytes(_ b: Double) -> String {
    if b >= GB { return String(format: "%.2f GB", b / GB) }
    return String(format: "%.0f MB", b / MB)
}

func fmtGB(_ b: Double) -> String { String(format: "%.2f GB", b / GB) }
func fmtMB(_ b: Double) -> String { String(format: "%.0f MB", b / MB) }

// MARK: - 采样模型

struct ProcRow: Identifiable {
    let id: Int32
    let name: String
    let bytes: Double
}

struct MemSample {
    var total: Double = 0
    var free: Double = 0
    var active: Double = 0
    var inactive: Double = 0
    var speculative: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var purgeable: Double = 0
    var uncompressedInComp: Double = 0
    var swapTotal: Double = 0
    var swapUsed: Double = 0
    var pressure: Int = 1
    var procs: [ProcRow] = []

    /// 与「内存压力」强相关的三项：内核 wired + 压缩内存 + 应用活跃
    var coreUsed: Double { wired + active + compressed }
    var ratio: Double { total > 0 ? min(1, max(0, coreUsed / total)) : 0 }
    var ratioPct: Int { Int((ratio * 100).rounded()) }
    var compRatio: Double { compressed > 0 ? uncompressedInComp / compressed : 0 }
    var pressureText: String {
        switch pressure {
        case 1: return "正常"
        case 2: return "警告"
        default: return "紧急"
        }
    }
}

// MARK: - 采样器

enum Sampler {

    static func readVM() -> (free: Double, active: Double, inactive: Double, spec: Double,
                             wired: Double, comp: Double, purgeable: Double, uncompInComp: Double)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ip, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = Double(pageSize)

        return (
            Double(stats.free_count) * ps,
            Double(stats.active_count) * ps,
            Double(stats.inactive_count) * ps,
            Double(stats.speculative_count) * ps,
            Double(stats.wire_count) * ps,
            Double(stats.compressor_page_count) * ps,
            Double(stats.purgeable_count) * ps,
            Double(stats.total_uncompressed_pages_in_compressor) * ps
        )
    }

    static func readSwap() -> (total: Double, used: Double) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            return (Double(xsw.xsu_total), Double(xsw.xsu_used))
        }
        return (0, 0)
    }

    static func readPressure() -> Int {
        var v: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0) == 0 {
            return Int(v)
        }
        return 1
    }

    /// 逐进程物理内存占用（Activity Monitor 的「内存」列口径：phys_footprint）
    static func readProcs(limit: Int) -> [ProcRow] {
        let cap = 8192
        var pids = [pid_t](repeating: 0, count: cap)
        let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.size * cap))
        let n = Int(used) / MemoryLayout<pid_t>.size
        guard n > 0 else { return [] }

        var rows: [ProcRow] = []
        rows.reserveCapacity(64)

        for i in 0..<min(n, cap) {
            let pid = pids[i]
            if pid <= 0 { continue }

            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) { p -> Int32 in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, rp)
                }
            }
            if ok != 0 { continue }

            let foot = Double(info.ri_phys_footprint)
            if foot < 8 * MB { continue }

            var nameBuf = [CChar](repeating: 0, count: 512)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            var nm = String(cString: nameBuf)

            // Electron / Helper / Renderer 这类进程名看不出是谁，从可执行路径反推 .app 名字
            var pathBuf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                let path = String(cString: pathBuf)
                if let r = path.range(of: ".app") {
                    let head = String(path[path.startIndex..<r.lowerBound])
                    if let comp = head.split(separator: "/").last.map(String.init), !comp.isEmpty {
                        nm = comp
                    }
                }
            }

            if nm.isEmpty { nm = "pid \(pid)" }

            rows.append(ProcRow(id: pid, name: nm, bytes: foot))
        }

        rows.sort { $0.bytes > $1.bytes }

        // 合并同名进程（Electron 类应用会分裂成很多子进程）
        var merged: [String: Double] = [:]
        var order: [String] = []
        for r in rows {
            if merged[r.name] == nil { order.append(r.name) }
            merged[r.name, default: 0] += r.bytes
        }
        var out: [ProcRow] = []
        for (i, e) in order.enumerated() {
            out.append(ProcRow(id: Int32(i), name: e, bytes: merged[e] ?? 0))
        }
        out.sort { $0.bytes > $1.bytes }
        return Array(out.prefix(limit))
    }

    /// 轻量：只读内核级内存统计（菜单栏用）
    static func light() -> MemSample {
        var s = MemSample()
        s.total = Double(ProcessInfo.processInfo.physicalMemory)
        if let vm = readVM() {
            s.free = vm.free
            s.active = vm.active
            s.inactive = vm.inactive
            s.speculative = vm.spec
            s.wired = vm.wired
            s.compressed = vm.comp
            s.purgeable = vm.purgeable
            s.uncompressedInComp = vm.uncompInComp
        }
        let sw = readSwap()
        s.swapTotal = sw.total
        s.swapUsed = sw.used
        s.pressure = readPressure()
        return s
    }

    /// 完整：附带进程榜（面板打开时用）
    static func full(limit: Int = 5) -> MemSample {
        var s = light()
        s.procs = readProcs(limit: limit)
        return s
    }
}

// MARK: - 菜单栏显示样式

enum BarStyle: String, CaseIterable, Identifiable {
    case bars   // 阶梯柱（信号格样式）
    case ring   // 圆环
    case text   // 色点 + 数字
    case chip   // 内存芯片图标

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bars: return "阶梯柱"
        case .ring: return "圆环"
        case .text: return "色点"
        case .chip: return "芯片"
        }
    }

    static let defaultsKey = "MemBarStyle"
}

// MARK: - 视图模型

@MainActor
final class MemModel: ObservableObject {
    @Published var sample = Sampler.light()
    @Published var history: [Double] = []
    @Published var style: BarStyle = .bars {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: BarStyle.defaultsKey) }
    }

    /// 读回上次选择的样式（在 App 启动时于主线程调用）
    func loadStylePreference() {
        let raw = UserDefaults.standard.string(forKey: BarStyle.defaultsKey) ?? ""
        style = BarStyle(rawValue: raw) ?? .bars
    }

    // MARK: 开机自启（走苹果官方 SMAppService，等价于「系统设置 → 通用 → 登录项」）

    @Published var autoStart = false
    @Published var autoStartMsg = ""

    func refreshAutoStart() {
        autoStart = (SMAppService.mainApp.status == .enabled)
    }

    func applyAutoStart(_ on: Bool) {
        do {
            let st = SMAppService.mainApp.status
            if on {
                if st != .enabled { try SMAppService.mainApp.register() }
            } else {
                if st == .enabled { try SMAppService.mainApp.unregister() }
            }
            autoStartMsg = ""
        } catch {
            autoStartMsg = "设置失败：\(error.localizedDescription)"
        }
        refreshAutoStart()
    }

    func refresh(deep: Bool) {
        let s = deep ? Sampler.full() : Sampler.light()
        sample = s
        history.append(s.ratio)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}

// MARK: - 配色

enum Palette {
    static let wired = Color(red: 0.64, green: 0.18, blue: 0.18)      // #A32D2D
    static let compressor = Color(red: 0.886, green: 0.294, blue: 0.290) // #E24B4A
    static let active = Color(red: 0.216, green: 0.541, blue: 0.867)   // #378ADD
    static let reclaim = Color(red: 0.522, green: 0.718, blue: 0.922)  // #85B7EB
    static let idle = Color.secondary.opacity(0.22)
}

// MARK: - 面板

struct PanelView: View {
    @ObservedObject var model: MemModel
    var onQuit: () -> Void
    var onRefresh: () -> Void
    var onStyleChange: () -> Void

    private var s: MemSample { model.sample }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            segBar.padding(.top, 12)
            legend.padding(.top, 10)
            Divider().opacity(0.5).padding(.vertical, 12)
            facts
            Divider().opacity(0.5).padding(.vertical, 12)
            procSection
            Divider().opacity(0.5).padding(.vertical, 12)
            styleSection
            Divider().opacity(0.5).padding(.vertical, 12)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 322)
        .onChange(of: model.style) { _ in onStyleChange() }
    }

    // ---- 顶部大数字 ----
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("内存").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("内核压力 " + s.pressureText)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(badgeBg, in: Capsule())
                    .foregroundStyle(badgeFg)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(s.ratioPct)%")
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text("已用 " + fmtGB(s.coreUsed))
                        .font(.system(size: 12)).monospacedDigit()
                    Text("共 " + fmtGB(s.total).replacingOccurrences(of: " GB", with: " GB"))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.bottom, 3)
                Spacer()
            }
        }
    }

    private var badgeBg: Color {
        switch s.pressure {
        case 1: return Color.green.opacity(0.16)
        case 2: return Color.orange.opacity(0.18)
        default: return Color.red.opacity(0.18)
        }
    }
    private var badgeFg: Color {
        switch s.pressure {
        case 1: return Color(red: 0.16, green: 0.52, blue: 0.25)
        case 2: return Color(red: 0.72, green: 0.44, blue: 0.03)
        default: return Color(red: 0.72, green: 0.20, blue: 0.20)
        }
    }

    // ---- 分段占位条 ----
    private var segments: [(String, Double, Color)] {
        [
            ("内核 wired", s.wired, Palette.wired),
            ("压缩内存", s.compressed, Palette.compressor),
            ("应用活跃", s.active, Palette.active),
            ("可回收缓存", s.inactive, Palette.reclaim),
        ]
    }

    private var segBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = max(s.total, 1)
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(seg.2)
                        .frame(width: max(0, w * (seg.1 / t) - 1.5))
                }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.idle)
                    .frame(minWidth: 0)
            }
        }
        .frame(height: 11)
    }

    private var legend: some View {
        VStack(spacing: 5) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                HStack(spacing: 8) {
                    Circle().fill(seg.2).frame(width: 8, height: 8)
                    Text(seg.0).font(.system(size: 12))
                    Spacer()
                    Text(fmtGB(seg.1)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Text("\(Int((seg.1 / max(s.total, 1) * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
            Text("菜单栏胶囊配色：< 75% 绿 · 75–88% 黄 · ≥ 88% 红")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ---- 关键事实 ----
    private var facts: some View {
        VStack(spacing: 5) {
            factRow("物理内存", fmtGB(s.total))
            factRow("Swap 已用", s.swapUsed > 0 ? fmtMB(s.swapUsed) + " / " + fmtMB(s.swapTotal)
                                              : "无（0 MB）")
            factRow("压缩比", s.compRatio > 0 ? String(format: "%.2f : 1", s.compRatio) : "—")
            factRow("压缩前原始数据", fmtGB(s.uncompressedInComp))
            factRow("空闲 + 可回收", fmtGB(s.free + s.inactive + s.speculative + s.purgeable))
        }
    }

    private func factRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 12)).monospacedDigit()
        }
    }

    // ---- 进程榜 ----
    private var procSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("占用最高的进程").font(.system(size: 11)).foregroundStyle(.secondary)
            if s.procs.isEmpty {
                Text("展开面板时读取…").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                let maxB = s.procs.first?.bytes ?? 1
                ForEach(s.procs) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(humanBytes(p.bytes)).font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1.5).fill(Palette.idle)
                                RoundedRectangle(cornerRadius: 1.5).fill(Palette.active.opacity(0.85))
                                    .frame(width: max(2, g.size.width * (p.bytes / max(maxB, 1))))
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("菜单栏显示方式").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("", selection: $model.style) {
                ForEach(BarStyle.allCases) { st in
                    Text(st.label).tag(st)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("点一下即时生效，已记住选择")
                .font(.system(size: 11)).foregroundStyle(.tertiary)

            Divider().opacity(0.5).padding(.vertical, 6)

            Toggle(isOn: Binding(
                get: { model.autoStart },
                set: { model.applyAutoStart($0) }
            )) {
                Text("开机自启").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if model.autoStartMsg.isEmpty {
                Text("注册到「系统设置 → 通用 → 登录项」")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Text(model.autoStartMsg)
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("每 2 秒刷新").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("刷新") { onRefresh() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            Button("退出") { onQuit() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated override init() { super.init() }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var host: NSHostingController<PanelView>!
    private let model = MemModel()
    private var timer: Timer?
    private var popoverOpen = false

    /// 让弹窗高度贴合 SwiftUI 内容的真实高度（否则会被裁掉）
    private static func fitSize(_ h: NSHostingController<PanelView>) -> NSSize {
        h.view.layoutSubtreeIfNeeded()
        let f = h.view.fittingSize
        if f.width < 100 || f.height < 100 {
            return NSSize(width: 322, height: 600)
        }
        return NSSize(width: ceil(f.width), height: ceil(f.height) + 6)
    }

    /// 防止双实例：launchd / 终端直接跑 binary 时，LaunchServices 不会帮我们去重
    private static func anotherInstanceRunning() -> Bool {
        // 调试参数（--show / --style=）需要允许并存，跳过保护
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let myPath = Bundle.main.executablePath else { return false }
        var pids = [pid_t](repeating: 0, count: 4096)
        let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.size * 4096))
        let n = Int(used) / MemoryLayout<pid_t>.size
        guard n > 0 else { return false }
        for i in 0..<min(n, 4096) {
            let pid = pids[i]
            if pid <= 0 || pid == me { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
               String(cString: buf) == myPath {
                return true
            }
        }
        return false
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // CLI：开机自启管理（供脚本/终端调用，不走 launchctl）
        let argv = CommandLine.arguments
        if argv.contains("--enable-autostart") || argv.contains("--disable-autostart")
            || argv.contains("--autostart-status") {
            let svc = SMAppService.mainApp
            if argv.contains("--enable-autostart") {
                do { try svc.register(); print("register: ok") }
                catch { print("register: FAILED — \(error.localizedDescription)") }
            }
            if argv.contains("--disable-autostart") {
                do { try svc.unregister(); print("unregister: ok") }
                catch { print("unregister: FAILED — \(error.localizedDescription)") }
            }
            print("SMAppService.mainApp.status = \(svc.status.rawValue)  (0=未注册 1=已启用 2=待用户批准 3=未找到)")
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)

        if Self.anotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading

        let root = PanelView(
            model: model,
            onQuit: { NSApp.terminate(nil) },
            onRefresh: { [weak self] in self?.model.refresh(deep: true) },
            onStyleChange: { [weak self] in self?.redrawStatusItem() }
        )
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        self.host = host

        popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.fitSize(host)

        model.loadStylePreference()
        model.refreshAutoStart()

        // 调试用：MemBar --style=bars|ring|text|chip 强制指定样式（用于截图对比）
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--style=") }) {
            if let st = BarStyle(rawValue: String(a.dropFirst("--style=".count))) {
                model.style = st
            }
        }

        model.refresh(deep: false)
        redrawStatusItem()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.refresh(deep: self.popoverOpen)
                self.redrawStatusItem()
            }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }

        // 调试用：MemBar --show 启动即弹出面板
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    @objc private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            popoverOpen = false
        } else {
            model.refresh(deep: true)
            redrawStatusItem()
            popover.contentSize = Self.fitSize(host)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            popoverOpen = true
        }
    }

    // ---- 菜单栏图标：4 种样式 ----
    private func redrawStatusItem() {
        guard let btn = statusItem.button else { return }
        // 注意：不能用 NSApp.effectiveAppearance —— 菜单栏文字颜色是按「壁纸亮度」
        // 由系统决定的（浅色模式 + 深色壁纸 = 白字），必须读状态栏按钮自己的 appearance
        let isDark = btn.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        let ratio = CGFloat(model.sample.ratio)
        let pct = "\(model.sample.ratioPct)%"
        let tint = Self.tintColor(ratio: model.sample.ratio, pressure: model.sample.pressure)
        let textColor: NSColor = isDark ? .white : .black
        let style = model.style

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textW = ceil((pct as NSString).size(withAttributes: attrs).width)

        let gap: CGFloat = 5
        let h: CGFloat = 18
        let graphicW: CGFloat
        switch style {
        case .bars: graphicW = 5 * 2.5 + 4 * 1.6
        case .ring: graphicW = 14
        case .chip: graphicW = 15
        case .text: graphicW = 7
        }
        let totalW = graphicW + gap + textW

        let img = NSImage(size: NSSize(width: totalW, height: h), flipped: false) { _ in
            switch style {
            case .bars:
                // 阶梯柱：像信号格，绝不会被误认成电池
                let heights: [CGFloat] = [4.0, 7.2, 10.4, 13.6, 16.8]
                let barW: CGFloat = 2.5, gapX: CGFloat = 1.6
                let maxH = heights[4]
                let filled = max(0, min(5, Int(ceil(Double(ratio) * 5.0 - 0.001))))
                for i in 0..<5 {
                    let bh = heights[i]
                    let x = CGFloat(i) * (barW + gapX)
                    let y = (h - maxH) / 2 + (maxH - bh)
                    let p = NSBezierPath(
                        roundedRect: NSRect(x: x, y: y, width: barW, height: bh),
                        xRadius: 1.1, yRadius: 1.1)
                    (i < filled ? tint : tint.withAlphaComponent(0.22)).setFill()
                    p.fill()
                }

            case .ring:
                // 圆环：像活动环，一眼区分于电池
                let lw: CGFloat = 2
                let d: CGFloat = 11.5
                let cx = d / 2 + lw / 2
                let cy = h / 2
                let r = (d - lw) / 2
                let track = NSBezierPath(
                    ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                track.lineWidth = lw
                tint.withAlphaComponent(0.22).setStroke()
                track.stroke()
                if ratio > 0.005 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                                  startAngle: 90, endAngle: 90 - 360 * ratio, clockwise: true)
                    arc.lineWidth = lw
                    arc.lineCapStyle = .round
                    tint.setStroke()
                    arc.stroke()
                }

            case .chip:
                // 内存芯片图标：最直白，就是「内存」
                let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
                if let base = NSImage(systemSymbolName: "memorychip",
                                      accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) {
                    let sz = base.size
                    let rect = NSRect(x: (graphicW - sz.width) / 2,
                                      y: (h - sz.height) / 2,
                                      width: sz.width, height: sz.height)
                    base.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceAtop)
                }

            case .text:
                // 只留一个色点，零图形歧义
                let dotD: CGFloat = 7
                let dot = NSBezierPath(
                    ovalIn: NSRect(x: 0, y: (h - dotD) / 2, width: dotD, height: dotD))
                tint.setFill()
                dot.fill()
            }

            // 百分比数字
            let ty = (h - font.ascender + font.descender) / 2 + 0.4
            (pct as NSString).draw(at: NSPoint(x: graphicW + gap, y: ty), withAttributes: attrs)
            return true
        }
        img.isTemplate = false

        btn.image = img
        btn.title = ""
        btn.imagePosition = .imageOnly
        btn.toolTip = String(
            format: "内存 %d%%（<75%% 绿 · 75–88%% 黄 · ≥88%% 红）\n内核压力 %@　wired %.2fG　压缩 %.2fG　Swap %.0fM\n样式：%@（可在面板里切换）",
            model.sample.ratioPct,
            model.sample.pressureText,
            model.sample.wired / GB,
            model.sample.compressed / GB,
            model.sample.swapUsed / MB,
            style.label)
    }

    private static func tintColor(ratio: Double, pressure: Int) -> NSColor {
        // 颜色必须和菜单栏上那个百分比同源、同刻度，否则用户会看到「60% 却是黄的」这种矛盾。
        // 分档阈值：<75% 绿 · 75–88% 黄 · ≥88% 红（已把 wired 约 22% 的固定底噪算进去）
        if pressure >= 4 { return NSColor.systemRed }   // 内核判定 CRITICAL 时直接红
        if ratio >= 0.88 { return NSColor.systemRed }
        if ratio >= 0.75 { return NSColor.systemOrange }
        return NSColor.systemGreen
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
