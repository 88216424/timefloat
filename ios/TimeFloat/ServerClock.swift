import Foundation
import SwiftUI

/// 一路时钟：把服务器时间映射到本地单调时钟上
///     服务器时间 = 单调时钟 + 偏移量 + 漂移率 × 距锚点时间
///
/// ★ 正确性保护：
///  1) 从未成功校时 → 不给任何数字（界面显示 --:--:--.---），
///     绝不退回本机墙钟冒充服务器时间；
///  2) 连续两轮之间真实偏移只可能有晶振漂移量级的变化，差得太多先不采纳，
///     等下一轮同方向确认，避免单次坏样本把钟面带偏（单调钟倒退=设备重启才无条件采纳）；
///  3) 界面常驻 ±不确定度 与"距今多久"。
final class ServerClock {
    enum State { case idle, syncing, ok, fail }
    enum ApplyResult { case applied, heldSuspicious }

    let source: TimeSource
    private(set) var state: State = .idle
    private(set) var errorText = ""
    private(set) var bestRttMs: Int64 = -1
    private(set) var uncertaintyMs: Int64 = -1
    private(set) var jitterMs: Int64 = 0
    private(set) var usedSamples = 0
    private(set) var totalSamples = 0
    private(set) var strategy = ""
    private(set) var preciseMs = false
    private(set) var syncCount = 0
    private(set) var synced = false
    private(set) var syncingSinceMono: Int64 = 0
    /// 最近一次「开始校时」的时刻：看门狗用它判断调度链是否断了（自愈兜底）
    private(set) var lastAttemptMonoMs: Int64 = 0

    var manualTrimMs: Int64 = 0

    private var offsetMs: Double = 0
    private var driftPpm: Double = 0
    private var anchorMonoMs: Int64 = 0
    private var lastOkMonoMs: Int64 = 0
    private var candidateOffset: Double = .nan
    private var candidateHits = 0

    var id: String { source.id }
    var label: String { source.label }

    var accentColor: Color {
        switch id {
        case "bj": return Color(red: 0.20, green: 0.78, blue: 0.35)
        case "taobao": return Color(red: 1.00, green: 0.42, blue: 0.00)
        case "jd": return Color(red: 0.88, green: 0.15, blue: 0.11)
        default: return .white
        }
    }

    init(_ source: TimeSource) { self.source = source }

    /// 未校时返回 nil —— 界面必须显示占位符，不能拿墙钟冒充
    func utcMsOrNil() -> Int64? {
        guard synced else { return nil }
        let mono = monoMs()
        let off = offsetMs + driftPpm * Double(mono - anchorMonoMs) / 1_000_000.0
        return Int64((Double(mono) + off).rounded()) + manualTrimMs
    }

    /// 便利方法：未校时返回本地墙钟。**故意设为 private** ——
    /// "绝不拿墙钟冒充服务器时间"是硬规矩，不能让它在别处被误用到显示路径上。
    private func nowUtcMs() -> Int64 { utcMsOrNil() ?? Int64(Date().timeIntervalSince1970 * 1000) }

    /// 本机墙钟相对**这一路服务器时钟**的偏差（毫秒）。
    /// 正数 = 本机比该服务器快，负数 = 本机比该服务器慢。
    /// 必须用"当前选中的那一路"来算 —— 抢购时关心的是自己和京东/淘宝服务器差多少，不是和 NTP 差多少。
    func localWallFastMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) - nowUtcMs()
    }

    func ageMs() -> Int64 {
        lastOkMonoMs == 0 ? Int64.max : max(0, monoMs() - lastOkMonoMs)
    }

    var isStale: Bool { synced && ageMs() > Cfg.staleMs }

    func markSyncing() {
        state = .syncing
        syncingSinceMono = monoMs()
        lastAttemptMonoMs = syncingSinceMono
    }

    func markFail(_ message: String) {
        errorText = message
        syncingSinceMono = 0
        state = synced ? .ok : .fail
    }

    @discardableResult
    func apply(_ s: SyncSummary) -> ApplyResult {
        let mono = monoMs()

        if synced && mono >= anchorMonoMs {
            let diff = abs(s.offsetMs - offsetMs)
            if diff > Cfg.jumpToleranceMs {
                if candidateOffset.isNaN || abs(s.offsetMs - candidateOffset) > Cfg.jumpAgreeMs {
                    candidateOffset = s.offsetMs
                    candidateHits = 1
                } else {
                    candidateHits += 1
                }
                if candidateHits < Cfg.jumpConfirmRounds {
                    errorText = "本轮结果与当前钟面差 \(Int64(s.offsetMs - offsetMs))ms，已暂缓采纳（等下一轮确认）"
                    state = .ok
                    strategy = s.strategy
                    return .heldSuspicious
                }
            }
        }
        candidateOffset = .nan
        candidateHits = 0

        if synced {
            let dt = Double(mono - anchorMonoMs)
            if dt > 5_000 {
                let instant = (s.offsetMs - offsetMs) / dt * 1_000_000.0
                driftPpm = driftPpm * 0.5 + min(max(instant, -2000), 2000) * 0.5
            }
        }
        offsetMs = s.offsetMs
        anchorMonoMs = mono
        bestRttMs = s.bestRttMs
        uncertaintyMs = s.uncertaintyMs
        jitterMs = s.jitterMs
        usedSamples = s.usedSamples
        totalSamples = s.totalSamples
        strategy = s.strategy
        preciseMs = s.preciseMs
        lastOkMonoMs = mono
        syncCount += 1
        errorText = ""
        syncingSinceMono = 0
        state = .ok
        synced = true
        return .applied
    }

    var statusColor: Color {
        if !synced {
            return state == .syncing ? .yellow : .red
        }
        if isStale { return .yellow }
        if !errorText.isEmpty { return .yellow }
        return .green
    }

    /// 主界面每路只显示这一行：**往返时间 + 多长时间前校准**
    /// （接口名、样本数、±不确定度这些技术细节不再往界面上堆）
    var briefLine: String {
        guard synced else {
            switch state {
            case .syncing: return "正在校准…"
            case .fail: return "校准失败"
            default: return "等待校准"
            }
        }
        return "往返 \(bestRttMs)ms · \(secText(ageMs()))前校准"
    }

    /// 供界面取颜色（0 正常 / 1 偏旧或上轮失败 / 2 还没校上），用颜色代替文字提示
    var healthLevel: Int {
        if !synced { return 2 }
        if isStale || !errorText.isEmpty { return 1 }
        return 0
    }

    private func secText(_ ms: Int64) -> String {
        if ms == Int64.max { return "从未" }
        if ms < 1000 { return "0s" }
        if ms < 60_000 { return "\(ms / 1000)s" }
        if ms < 3_600_000 { return "\(ms / 60_000)m\((ms % 60_000) / 1000)s" }
        return "\(ms / 3_600_000)h"
    }
}

/// Equatable 是给 ClockHub.tick() 做"值没变就不发布"用的（省掉每帧无意义的整树重绘）
struct ClockLine: Identifiable, Equatable {
    let id: String
    let name: String
    let shortName: String
    let time: String
    let deltaText: String
    let color: Color
    let failed: Bool
}
