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
    /// 由 MemModel 注入：每个进程 footprint 的增速（字节/分钟）。
    /// 只有跨两次采样才算得出来，所以首次打开面板时是空的。
    var procGrowth: [String: Double] = [:]

    /// 累计换出次数（内核计数器，单调递增，永不清零 —— 单看它没有意义）
    var swapouts: UInt64 = 0
    /// 由 MemModel 注入：最近一分钟换出次数，这才是当下的体感来源
    var swapRate: Double = 0
    /// 由 MemModel 注入：最近 30 次采样里每格是否发生换页（0/1）
    var swapBeats: [Int] = []

    /// 与「内存压力」强相关的三项：内核 wired + 压缩内存 + 应用活跃
    var coreUsed: Double { wired + active + compressed }
    /// 随时能腾出来的量：空闲 + 非活跃 + 预读 + 可清除
    var reclaimable: Double { free + inactive + speculative + purgeable }
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

    /// 一句话结论：比百分比更能回答「我现在有事没事」
    var verdict: (text: String, level: Int) {
        if pressure >= 4 { return ("内存紧急", 2) }
        if pressure >= 2 { return ("内存紧张", 2) }
        if swapRate >= 120 { return ("换页频繁", 1) }
        if swapRate >= 12 { return ("轻微换页", 1) }
        return ("内存稳定", 0)
    }
}

// MARK: - 采样器

enum Sampler {

    static func readVM() -> (free: Double, active: Double, inactive: Double, spec: Double,
                             wired: Double, comp: Double, purgeable: Double, uncompInComp: Double,
                             swapouts: UInt64)? {
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
            Double(stats.total_uncompressed_pages_in_compressor) * ps,
            stats.swapouts
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

            // 从可执行路径反推所属 .app：取「最外层」以 .app 结尾的路径段。
            // 不能用 range(of: ".app") 做子串匹配 —— "com.apple..." 本身就含 ".app"，
            // 会把 Safari 网页进程（com.apple.WebKit.WebContent）截成 "com"。
            var pathBuf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                let path = String(cString: pathBuf)
                if let comp = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
                    let app = String(comp.dropLast(4))
                    if !app.isEmpty { nm = app }
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
            s.swapouts = vm.swapouts
        }
        let sw = readSwap()
        s.swapTotal = sw.total
        s.swapUsed = sw.used
        s.pressure = readPressure()
        return s
    }

    /// 完整：附带进程榜（面板打开时用）
    /// 取 10 个而不是 5 个 —— 榜上只显示 5 行，但要多采几个才能算出「谁在涨」，
    /// 否则一个排第 6、正在猛涨的进程永远进不了视野。
    static func full(limit: Int = 10) -> MemSample {
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
    /// 菜单栏专用：非 @Published，刷新时不触发 SwiftUI 通知
    /// （面板关闭时若还走 @Published，@Published 会每 2 秒让整棵视图树重算一遍）
    var barSample = Sampler.light()
    @Published var history: [Double] = []
    @Published var style: BarStyle = .bars {
        didSet {
            // 调试参数 --style= 只影响本次进程，不该把用户的偏好覆盖掉
            guard persistStyle else { return }
            UserDefaults.standard.set(style.rawValue, forKey: BarStyle.defaultsKey)
        }
    }
    var persistStyle = true
    /// 进程榜排序方式：0 = 占用，1 = 增长（放在这里而不是 @State，命令行 swiftc 构建下宏不可用）
    @Published var procMode = 0

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
        var s = deep ? Sampler.full() : Sampler.light()
        trackSwap(&s)
        if deep { trackProcGrowth(&s) }
        barSample = s                  // 菜单栏永远拿最新值，且不产生 SwiftUI 通知
        guard deep else { return }     // 面板关闭时到此为止：不碰 @Published
        sample = s
        history.append(s.ratio)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }

    // MARK: 换页活动追踪

    /// 内核换出计数器只增不减，必须差分才能看出「此刻在不在换页」。
    /// 面板关着也照跑，这样一打开就有完整的心跳历史。
    private var lastSwapouts: UInt64 = 0
    private var lastSwapAt = Date()
    private var swapBeats = [Int](repeating: 0, count: 30)
    private var swapRate: Double = 0

    private func trackSwap(_ s: inout MemSample) {
        let now = Date()
        let dt = now.timeIntervalSince(lastSwapAt)

        if lastSwapouts > 0, dt > 0.5, s.swapouts >= lastSwapouts {
            let delta = Double(s.swapouts - lastSwapouts)
            let instant = delta / dt * 60
            // 指数平滑，避免单次 0 换出就把速率打成 0 造成闪烁
            swapRate = swapRate * 0.6 + instant * 0.4
            if instant == 0 && swapRate < 1 { swapRate = 0 }
            swapBeats.append(delta > 0 ? 1 : 0)
            if swapBeats.count > 30 { swapBeats.removeFirst(swapBeats.count - 30) }
        }

        lastSwapouts = s.swapouts
        lastSwapAt = now
        s.swapRate = swapRate
        s.swapBeats = swapBeats
    }

    // MARK: 进程增速追踪（P2）

    /// 「谁在涨」比「谁最大」有用：拖垮 8G 机器的从来是持续增长的那个。
    /// 只在面板打开时采样（deep），所以关着面板不产生任何额外开销。
    /// 速率按「最近 60 秒内最早一次采样」为基准算，而不是只跟上一次比 ——
    /// 单次 5 秒的差值太吵，进程一启动就是几百 MB/分，全是假警报。
    private var procHist: [String: [(t: Date, b: Double)]] = [:]
    private var procGrowth: [String: Double] = [:]

    private func trackProcGrowth(_ s: inout MemSample) {
        guard !s.procs.isEmpty else { return }
        let now = Date()
        var next: [String: Double] = [:]

        for p in s.procs {
            var h = procHist[p.name] ?? []
            h.append((now, p.bytes))
            h.removeAll { now.timeIntervalSince($0.t) > 60 }
            procHist[p.name] = h
            guard let first = h.first else { continue }
            let dt = now.timeIntervalSince(first.t)
            guard dt >= 4 else { continue }        // 窗口太短，差值不可信
            next[p.name] = (p.bytes - first.b) / dt * 60
        }

        // 掉了的进程不再留着，避免字典无限增长
        let alive = Set(s.procs.map { $0.name })
        procHist = procHist.filter { alive.contains($0.key) }

        procGrowth = next
        s.procGrowth = next
    }
}

// MARK: - 配色

enum Palette {
    // 段条按「能不能腾出来」排序配色，不是按危险程度：
    // 左边实心是动不了的墙，右边越淡越容易丢。
    static let wired = Color(red: 0.373, green: 0.369, blue: 0.353)      // #5F5E5A 中性
    static let compressor = Color(red: 0.114, green: 0.620, blue: 0.459)  // #1D9E75 系统的努力
    static let active = Color(red: 0.216, green: 0.541, blue: 0.867)      // #378ADD 在用
    static let reclaim = Color(red: 0.706, green: 0.698, blue: 0.663).opacity(0.42) // 可回收
    static let idle = Color.secondary.opacity(0.22)

    static let beatHot = Color(red: 0.937, green: 0.624, blue: 0.153)     // #EF9F27
    static let beatCool = Color(red: 0.592, green: 0.769, blue: 0.349)    // #97C459

    static let good = Color(red: 0.369, green: 0.600, blue: 0.176)
    static let warn = Color(red: 0.729, green: 0.459, blue: 0.090)
    static let bad = Color(red: 0.816, green: 0.176, blue: 0.176)

    static func verdictColor(_ level: Int) -> Color {
        switch level {
        case 1: return warn
        case 2: return bad
        default: return good
        }
    }
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
            segBar.padding(.top, 11)
            legend.padding(.top, 9)
            Divider().opacity(0.5).padding(.vertical, 11)
            beatRow
            facts.padding(.top, 9)
            Divider().opacity(0.5).padding(.vertical, 11)
            procSection
            Divider().opacity(0.5).padding(.vertical, 11)
            styleSection
            Divider().opacity(0.5).padding(.vertical, 11)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 322)
        .onChange(of: model.style) { _ in onStyleChange() }
    }

    // ---- 顶部：一句话结论，不是百分比 ----
    private var header: some View {
        let v = s.verdict
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Palette.verdictColor(v.level))
                    .frame(width: 7, height: 7)
                Text(v.text)
                    .font(.system(size: 17, weight: .medium))
                Spacer()
                Text("压力 " + s.pressureText)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(badgeBg, in: Capsule())
                    .foregroundStyle(badgeFg)
            }
            HStack(spacing: 6) {
                Text(fmtGB(s.coreUsed) + " / " + fmtGB(s.total))
                    .font(.system(size: 12, design: .monospaced))
                Text("余量 " + fmtGB(s.reclaimable))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
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

    // ---- 分段占位条：按「能不能腾出来」从左到右排 ----
    private var segments: [(String, Double, Color)] {
        [
            ("内核 wired", s.wired, Palette.wired),
            ("应用活跃", s.active, Palette.active),
            ("压缩内存", s.compressed, Palette.compressor),
            ("可回收缓存", s.reclaimable, Palette.reclaim),
        ]
    }

    private var segBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let sum = segments.reduce(0) { $0 + $1.1 }
            let t = max(s.total, sum, 1)
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(seg.2)
                        .frame(width: max(0, w * (seg.1 / t) - 1.5))
                }
            }
        }
        .frame(height: 11)
    }

    private var legend: some View {
        let sum = segments.reduce(0) { $0 + $1.1 }
        let t = max(s.total, sum, 1)
        return VStack(spacing: 5) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                HStack(spacing: 6) {
                    Circle().fill(seg.2).frame(width: 8, height: 8)
                    Text(seg.0).font(.system(size: 12))
                    if seg.0 == "压缩内存", s.compRatio > 0.05 {
                        Text(String(format: "%.1f×", s.compRatio))
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.compressor.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Palette.compressor)
                    }
                    Spacer(minLength: 4)
                    Text(fmtGB(seg.1)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Text("\(Int((seg.1 / t * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
            Text("左侧实心不可回收 · 右侧浅色随时能腾")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ---- 换页心跳：看的是「此刻在不在动」，不是累计值 ----
    private var beatRow: some View {
        let rate = s.swapRate
        let hot = rate >= 1
        return HStack(spacing: 8) {
            Text("换页").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(s.swapBeats.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(v > 0 ? Palette.beatHot : Palette.beatCool.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: v > 0 ? 10 : 6)
                }
            }
            .frame(height: 10, alignment: .bottom)
            .background(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.10))
                    .frame(height: 10)
            }
            Text(rate < 1 ? "0 次/分" : String(format: "%.0f 次/分", rate))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(hot ? Palette.beatHot : Color.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    // ---- 关键事实 ----
    private var facts: some View {
        VStack(spacing: 5) {
            factRow("物理内存", fmtGB(s.total))
            factRow("Swap 已用", s.swapUsed > 0 ? fmtMB(s.swapUsed) + " / " + fmtMB(s.swapTotal)
                                              : "无（0 MB）")
            factRow("压缩前原始数据", fmtGB(s.uncompressedInComp))
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
    /// 0 = 按占用，1 = 按增长速度（放在 model 里：本工程用命令行 swiftc 构建，@State 宏不可用）
    private var procMode: Int { model.procMode }

    private var procRows: [ProcRow] {
        let base = s.procs
        if procMode == 0 {
            return Array(base.sorted { $0.bytes > $1.bytes }.prefix(5))
        }
        return Array(base.sorted {
            (s.procGrowth[$0.name] ?? -Double.greatestFiniteMagnitude)
                > (s.procGrowth[$1.name] ?? -Double.greatestFiniteMagnitude)
        }.prefix(5))
    }

    private var procSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(procMode == 0 ? "占用最高的进程" : "涨得最快的进程")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.procMode },
                    set: { model.procMode = $0 }
                )) {
                    Text("占用").tag(0)
                    Text("增长").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 92)
            }

            if s.procs.isEmpty {
                Text("展开面板时读取…").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else if procMode == 1 && s.procGrowth.isEmpty {
                Text("测量中：需要两次采样，约 5 秒后出现…")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                let rows = procRows
                let maxB = max(rows.first?.bytes ?? 1, 1)
                // 分母至少 10 MB/分：否则几十 KB 的抖动会被放大成满格，与「持平」字样自相矛盾
                let maxG = max(rows.compactMap { s.procGrowth[$0.name] }.filter { $0 > 0 }.max() ?? 0, 10 * MB)
                ForEach(rows) { p in
                    let g = s.procGrowth[p.name] ?? 0
                    let isGrow = procMode == 1
                    // 增长模式下 < 1 MB/分 视为持平，条长为 0，和文字保持一致
                    let frac = isGrow ? (g > MB ? g / maxG : 0) : p.bytes / maxB
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if isGrow {
                                Text(growthText(g))
                                    .font(.system(size: 12)).monospacedDigit()
                                    .foregroundStyle(g > 2 * MB ? Palette.warn
                                                     : (g > 0 ? Color.secondary : Color.secondary.opacity(0.6)))
                            }
                            Text(humanBytes(p.bytes)).font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(isGrow ? .tertiary : .secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1.5).fill(Palette.idle)
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(isGrow ? Palette.beatHot.opacity(0.85) : Palette.active.opacity(0.85))
                                    .frame(width: isGrow ? geo.size.width * min(1, max(0, frac))
                                                         : max(2, geo.size.width * min(1, max(0, frac))))
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
    }

    private func growthText(_ bytesPerMin: Double) -> String {
        if bytesPerMin >= 0.95 * GB { return String(format: "+%.1f GB/分", bytesPerMin / GB) }
        if bytesPerMin >= 1 * MB { return String(format: "+%.0f MB/分", bytesPerMin / MB) }
        if bytesPerMin <= -1 * MB { return String(format: "%.0f MB/分", bytesPerMin / MB) }
        return "持平"
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
            Text("形状 = 占用比例　颜色 = 压力　数字 = 可释放余量")
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
            Text("每 5 秒刷新").font(.system(size: 11)).foregroundStyle(.tertiary)
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
    /// 调试用：把面板塞进独立窗口，避免 NSPopover 的 transient 行为导致截图时自动关闭
    private var debugWindow: NSWindow?
    // 菜单栏图标缓存：数值没变就复用同一个 NSImage，避免每 2 秒重建位图并上传 WindowServer
    private var drawKey = ""
    private var lastTip = ""
    private var lastText = ""

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
            onRefresh: { [weak self] in
                self?.model.refresh(deep: true)
                self?.redrawStatusItem()
            },
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

        // 调试用：MemBar --proc=growth 直接以「增长」排序打开面板（截图核对用）
        model.procMode = CommandLine.arguments.contains("--proc=growth") ? 1 : 0

        // 调试用：MemBar --style=bars|ring|text|chip 强制指定样式（用于截图对比，不写入偏好）
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--style=") }) {
            if let st = BarStyle(rawValue: String(a.dropFirst("--style=".count))) {
                model.persistStyle = false
                model.style = st
            }
        }

        model.refresh(deep: false)
        redrawStatusItem()

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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

        // 调试用：MemBar --panel-window 把面板放进独立浮动窗口，便于截图核对布局
        if CommandLine.arguments.contains("--panel-window") {
            popoverOpen = true   // 让定时器继续走 deep 采样，否则进程增速永远是空的
            model.refresh(deep: true)
            let pv = PanelView(model: model, onQuit: {}, onRefresh: {}, onStyleChange: {})
            let c = NSHostingController(rootView: pv)
            c.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 760),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.contentViewController = c
            w.title = "MemBar Panel"
            w.setContentSize(c.view.fittingSize)
            w.center()
            w.level = .floating
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            debugWindow = w
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

        let s = model.barSample
        let ratio = CGFloat(s.ratio)
        // 菜单栏显示「还能腾出多少」，而不是「占了多少」：
        // 前者自己就是答案，后者还要用户知道多少算多。副屏/余光场景下差别很大。
        let text = Self.remainText(s.reclaimable)
        let tint = Self.tintColor(pressure: s.pressure, swapRate: s.swapRate)
        let textColor: NSColor = isDark ? .white : .black
        let style = model.style

        // toolTip 不涉及位图，但同样去重，否则每次采样都会推一次状态栏更新
        let tip = s.verdict.text
            + String(format: "　余量 %.2fG / 共 %.2fG\n换页 %.0f 次/分　wired %.2fG　压缩 %.2fG（%.1f×）",
                     s.reclaimable / GB, s.total / GB, s.swapRate,
                     s.wired / GB, s.compressed / GB, s.compRatio)
            + "\n样式：\(style.label)（可在面板里切换）"
        if tip != lastTip { btn.toolTip = tip; lastTip = tip }

        // 位图只在「图形真需要变」时重建：柱格数 / 圆环弧长 / 颜色档位 / 样式 / 明暗。
        // 文字不画进位图，改走 attributedTitle —— 它每次采样都会变，
        // 画进位图等于每次重建一张位图并上传 WindowServer，那才是 CPU 的大头。
        // 颜色档位跟内核压力/换页走，不再跟「已用百分比」走：
        // Mac 的已用比例常年 70~85% 却毫无问题，用它上色只会一直黄。
        let tier = Self.tintTier(pressure: s.pressure, swapRate: s.swapRate)
        let shape: String
        switch style {
        case .bars: shape = "\(max(0, min(5, Int(ceil(Double(ratio) * 5.0 - 0.001)))))"
        case .ring: shape = "\(Int((Double(ratio) * 10).rounded()))"
        default:    shape = "\(tier)"
        }
        let key = "\(shape)|\(tier)|\(style.rawValue)|\(isDark)"

        let h: CGFloat = 18
        let graphicW: CGFloat
        switch style {
        case .bars: graphicW = 5 * 2.5 + 4 * 1.6
        case .ring: graphicW = 14
        case .chip: graphicW = 15
        case .text: graphicW = 7
        }

        if key != drawKey {
        drawKey = key
        let img = NSImage(size: NSSize(width: graphicW, height: h), flipped: false) { _ in
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

            return true
        }
        img.isTemplate = false
        btn.image = img
        btn.imagePosition = .imageLeading
        }

        // 文字单独更新：只改文本属性，不重建位图
        if text != lastText {
            lastText = text
            btn.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                             .foregroundColor: textColor])
        }
    }

    /// 余量文案：>= 1G 用 1.4G，否则用 820M。字体等宽，宽度变化不会顶动别的图标。
    private static func remainText(_ bytes: Double) -> String {
        if bytes >= GB { return String(format: "%.1fG", bytes / GB) }
        if bytes >= 100 * MB { return String(format: "%.0fM", bytes / MB) }
        return String(format: "%.0fM", max(0, bytes / MB))
    }

    /// 颜色只看「有没有出事」，不看占用比例 —— Mac 的 80% 通常是健康的
    private static func tintTier(pressure: Int, swapRate: Double) -> Int {
        if pressure >= 2 { return 2 }        // 内核判 WARN / CRITICAL
        if swapRate >= 120 { return 2 }      // 每分钟百次以上换页，已经在硬扛
        if swapRate >= 12 { return 1 }
        return 0
    }

    private static func tintColor(pressure: Int, swapRate: Double) -> NSColor {
        switch tintTier(pressure: pressure, swapRate: swapRate) {
        case 2: return NSColor.systemRed
        case 1: return NSColor.systemOrange
        default: return NSColor.systemGreen
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
