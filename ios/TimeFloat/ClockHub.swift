import Foundation
import SwiftUI

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
        timer = Timer.scheduledTimer(withTimeInterval: Cfg.uiTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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
        for c in clocks {
            Task { [weak self] in
                c.markSyncing()
                do {
                    let s = try await Sampler.run(c.source)
                    c.apply(s)
                } catch {
                    c.markFail(error.localizedDescription)
                }
                self?.tick()
            }
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

    private func syncLoopOnce(_ clock: ServerClock) async {
        guard !inFlight.contains(clock.id) else { return }
        inFlight.insert(clock.id)
        defer { inFlight.remove(clock.id) }
        clock.markSyncing()
        do {
            let s = try await Sampler.run(clock.source)
            clock.apply(s)
        } catch {
            clock.markFail(error.localizedDescription)
        }
        tick()
    }

    private func syncLoop(_ clock: ServerClock) async {
        while running {
            await syncLoopOnce(clock)
            guard running else { break }
            let delay: UInt64
            if clock.state == .ok {
                delay = clock.preciseMs ? Cfg.resyncPreciseMs : Cfg.resyncCoarseMs
            } else {
                delay = Cfg.retryOnFailMs
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
    }

    // MARK: - 每秒 20 次的界面刷新

    private func tick() {
        let bj = beijing.utcMsOrNil()
        let tb = taobao.utcMsOrNil()
        let jd = jd.utcMsOrNil()

        func line(_ c: ServerClock, _ t: Int64?, _ base: Int64?) -> ClockLine {
            let time = t.map { Fmt.hms($0) } ?? "--:--:--.---"
            var delta = "基准"
            if c.id != "bj" {
                if let t = t, let base = base { delta = Fmt.delta(t - base) + "ms" } else { delta = "--" }
            }
            return ClockLine(id: c.id, name: c.label, shortName: c.label, time: time,
                             deltaText: delta, color: c.accentColor, failed: !c.synced && c.state == .fail)
        }

        lines = [line(beijing, bj, bj), line(taobao, tb, bj), line(jd, jd, bj)]

        // ★ 本机墙钟 vs「当前选中的那一路服务器」——不是写死北京时间
        let sel = selected
        if sel.utcMsOrNil() == nil {
            localSkewText = "本机墙钟：\(sel.label)服务器还没校上，暂时比不出来"
            localSkewTint = .yellow
        } else {
            let fast = sel.localWallFastMs()
            localSkewText = fast >= 0
                ? "本机墙钟比\(sel.label)服务器快 \(fast)ms"
                : "本机墙钟比\(sel.label)服务器慢 \(-fast)ms"
            localSkewTint = abs(fast) <= 50 ? .green : (abs(fast) <= 200 ? .yellow : .red)
        }

        let cross = crossCheck()
        switch cross.level {
        case 0:
            crossText = "\(cross.text) · 一致（可信）"
            crossTint = .green
        case 1:
            crossText = "\(cross.text) · 略有差异"
            crossTint = .yellow
        case 2...:
            crossText = "\(cross.text) · 差异偏大，注意核对"
            crossTint = .red
        default:
            crossText = cross.text          // 可用源不足，别硬拼"略有差异"
            crossTint = .gray
        }

        detailText = clocks.map { "\($0.label)  \($0.briefLine)" }.joined(separator: "\n")
    }
}
