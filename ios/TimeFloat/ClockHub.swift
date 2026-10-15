import Foundation
import SwiftUI
import UIKit

/// 三路时钟总调度。主界面和画中画浮窗读同一份数据，显示永远一致。
///
/// 与 Android 端一致的三条规矩：
///  1) 一直显示的是"选中的那一路"，切源只在启动画中画之前做；
///  2) 没有成功校时过的源不显示数字（占位符），绝不拿本机墙钟冒充；
///  3) 常驻显示不确定度和三源互差，时间可不可信一眼看出来。
@MainActor
final class ClockHub: ObservableObject {
    static let shared = ClockHub()

    @Published var lines: [ClockLine] = []
    @Published var localSkewText = "本机墙钟：正在校时…"
    @Published var localSkewTint: Color = .yellow
    @Published var crossText = "三源互差：等待校时"
    @Published var crossTint: Color = .gray
    @Published var detailText = ""
    @Published var selectedId: String = UserDefaults.standard.string(forKey: "floatSrc") ?? "taobao"

    let clocks: [ServerClock] = [ServerClock(BeijingSource()),
                                 ServerClock(TaobaoSource()),
                                 ServerClock(JdSource())]

    var beijing: ServerClock { clocks[0] }
    var taobao: ServerClock { clocks[1] }
    var jd: ServerClock { clocks[2] }

    var selected: ServerClock { clocks.first { $0.id == selectedId } ?? taobao }

    func clock(_ id: String) -> ServerClock? { clocks.first { $0.id == id } }

    private var timer: Timer?
    private var loops: [Task<Void, Never>] = []
    private var watchdog: Task<Void, Never>?
    /// 正在校时中的源（防止看门狗和主循环同时给同一个源发请求）
    private var inFlight: Set<String> = []
    private(set) var running = false

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        // ★ 必须加进 .common 模式：Timer.scheduledTimer 只注册 .default，
        //   而用户拖动列表/滚动时主 run loop 会切到 UITracking 模式 →
        //   tick() 停摆 → App 内三行时间和浮卡全都"冻住"，松手才恢复。
        let t = Timer(timeInterval: Cfg.uiTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        for c in clocks {
            loops.append(Task { [weak self] in await self?.syncLoop(c) })
        }
        watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.running else { return }
                self.checkStuck()
            }
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        watchdog?.cancel()
        watchdog = nil
        for t in loops { t.cancel() }
        loops.removeAll()
        // 注意：不动时钟状态，避免下次打开显示成"校时中"
    }

    func refreshAll() {
        // ★ 走 syncLoopOnce 而不是自己 new Task：它会登记 inFlight，
        //   否则手动刷新和看门狗自愈可能同时对同一个源发两轮请求，
        //   两个结果乱序写回同一个时钟。
        for c in clocks {
            Task { [weak self] in await self?.syncLoopOnce(c) }
        }
    }

    func select(_ id: String) {
        selectedId = id
        UserDefaults.standard.set(id, forKey: "floatSrc")
        tick()
    }

    /// 三源互差；level: -1 = 可用源不足 / 0 一致 / 1 略有差异 / 2 差异偏大
    func crossCheck() -> (spread: Int64, level: Int, text: String) {
        let live = clocks.compactMap { $0.utcMsOrNil() }
        guard live.count >= 2 else { return (-1, -1, "可用源不足，等待校时") }
        let spread = (live.max() ?? 0) - (live.min() ?? 0)
        let level = spread <= Cfg.crossOkMs ? 0 : (spread <= Cfg.crossWarnMs ? 1 : 2)
        return (spread, level, "三源互差 \(spread)ms")
    }

    /// 看门狗：卡死处理 + **调度自愈**（超过 90 秒没开始过校时就直接补一次，
    /// 保证自动校时永远不会因为某条链断掉而彻底停住）
    private func checkStuck() {
        let now = monoMs()
        for c in clocks {
            if c.syncingSinceMono > 0 && now - c.syncingSinceMono > Cfg.stuckMs {
                c.markFail("校时超时，已自动重排")
            }
            if !inFlight.contains(c.id) {
                let since = c.lastAttemptMonoMs
                if since == 0 || now - since > Cfg.selfHealMs {
                    Task { [weak self] in await self?.syncLoopOnce(c) }
                }
            }
        }
    }

    @discardableResult
    private func syncLoopOnce(_ clock: ServerClock) async -> Bool {
        guard !inFlight.contains(clock.id) else { return false }
        inFlight.insert(clock.id)
        defer { inFlight.remove(clock.id) }
        clock.markSyncing()
        var held = false
        do {
            let s = try await Sampler.run(clock.source)
            held = clock.apply(s) == .heldSuspicious
        } catch {
            clock.markFail(error.localizedDescription)
        }
        tick()
        return held
    }

    private func syncLoop(_ clock: ServerClock) async {
        while running {
            let held = await syncLoopOnce(clock)
            guard running else { break }
            let delay: UInt64
            if held {
                // 被"暂缓采纳"时要尽快来第二轮确认，别等 60 秒
                delay = Cfg.retryOnFailMs
            } else if clock.state == .ok {
                delay = clock.preciseMs ? Cfg.resyncPreciseMs : Cfg.resyncCoarseMs
            } else {
                delay = Cfg.retryOnFailMs
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
    }

    // MARK: - 每秒 20 次的界面刷新

    private func tick() {
        // 退到后台就不用刷 App 内界面了 —— 浮窗是 PipClock 自己按帧画的，不依赖这个 tick。
        // 但**校时循环照常跑**：后台正是"用别的 App 时浮窗要准"的主场景。
        // 这样既省掉后台 20fps 的字符串格式化，又不会让浮窗数据变旧。
        if UIApplication.shared.applicationState == .background { return }

        // 注意变量名：不能叫 bj/tb/jd，否则会把同名的时钟属性遮住（Swift 会报类型不匹配）
        let bjMs = beijing.utcMsOrNil()
        let tbMs = taobao.utcMsOrNil()
        let jdMs = jd.utcMsOrNil()

        func line(_ c: ServerClock, _ t: Int64?, _ base: Int64?) -> ClockLine {
            let time = t.map { Fmt.hms($0) } ?? "--:--:--.---"
            var delta = "基准"
            if c.id != "bj" {
                if let t = t, let base = base { delta = Fmt.delta(t - base) + "ms" } else { delta = "--" }
            }
            return ClockLine(id: c.id, name: c.label, shortName: c.label, time: time,
                             deltaText: delta, color: c.accentColor, failed: !c.synced && c.state == .fail)
        }

        // ★ 先算成局部值，**只有真的变了才赋值给 @Published**。
        //   这个函数每帧都在跑（默认 20~30fps），@Published 每次赋值都会让 SwiftUI
        //   重建整棵视图树 —— 不守卫的话界面 24 小时都在空转重绘（耗电 + 掉帧）。
        let newLines = [line(beijing, bjMs, bjMs), line(taobao, tbMs, bjMs), line(jd, jdMs, bjMs)]

        // ★ 本机墙钟 vs「当前选中的那一路服务器」——不是写死北京时间
        let sel = selected
        let newSkewText: String
        let newSkewTint: Color
        if sel.utcMsOrNil() == nil {
            newSkewText = "本机墙钟：\(sel.label)服务器还没校上，暂时比不出来"
            newSkewTint = .yellow
        } else {
            let fast = sel.localWallFastMs()
            newSkewText = fast >= 0
                ? "本机墙钟比\(sel.label)服务器快 \(fast)ms"
                : "本机墙钟比\(sel.label)服务器慢 \(-fast)ms"
            newSkewTint = abs(fast) <= 50 ? .green : (abs(fast) <= 200 ? .yellow : .red)
        }

        let cross = crossCheck()
        let newCrossText: String
        let newCrossTint: Color
        switch cross.level {
        case 0:
            newCrossText = "\(cross.text) · 一致（可信）"
            newCrossTint = .green
        case 1:
            newCrossText = "\(cross.text) · 略有差异"
            newCrossTint = .yellow
        case 2...:
            newCrossText = "\(cross.text) · 差异偏大，注意核对"
            newCrossTint = .red
        default:
            newCrossText = cross.text          // 可用源不足，别硬拼"略有差异"
            newCrossTint = .gray
        }

        let newDetail = clocks.map { "\($0.label)  \($0.briefLine)" }.joined(separator: "\n")

        if newLines != lines { lines = newLines }
        if newSkewText != localSkewText { localSkewText = newSkewText }
        if newSkewTint != localSkewTint { localSkewTint = newSkewTint }
        if newCrossText != crossText { crossText = newCrossText }
        if newCrossTint != crossTint { crossTint = newCrossTint }
        if newDetail != detailText { detailText = newDetail }
    }
}
