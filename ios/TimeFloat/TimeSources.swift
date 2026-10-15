import Foundation

/// 一次原始采样结果
struct RawSync {
    let serverUtcMsAtRecv: Int64
    let monoMsAtRecv: Int64
    let rttMs: Int64
    let strategy: String
    let preciseMs: Bool
    var offsetMs: Int64 { serverUtcMsAtRecv - monoMsAtRecv }
}

protocol TimeSource {
    var id: String { get }
    var label: String { get }
    var preferredSamples: Int { get }
    var extraUncertaintyMs: Int64 { get }
    /// 源内部已经做了多次采样聚合（Date 头秒边界交集），Sampler 不该再叠加 rtt/2
    var selfAggregated: Bool { get }
    func fetch() async throws -> RawSync
}

extension TimeSource {
    var preferredSamples: Int { Cfg.samplesPerSync }
    var extraUncertaintyMs: Int64 { 0 }
    var selfAggregated: Bool { false }
}

enum Cfg {
    // 采样
    static let samplesPerSync = 4
    static let sampleGapMs: UInt64 = 90
    static let syncBudgetMs: Int64 = 12_000
    static let minRttWindowRatio = 0.4
    static let outlierMs: Double = 40

    // 正确性保护
    static let jumpToleranceMs: Double = 1_000
    static let jumpAgreeMs: Double = 300
    static let jumpConfirmRounds = 2
    static let crossOkMs: Int64 = 50
    static let crossWarnMs: Int64 = 200
    static let staleMs: Int64 = 150_000

    // 周期
    static let resyncPreciseMs: UInt64 = 60_000
    static let resyncCoarseMs: UInt64 = 90_000
    static let retryOnFailMs: UInt64 = 6_000
    /// 判定"卡死"的阈值，必须**明显大于**一轮采样的最坏耗时，否则正常慢网络会被误判：
    /// 最坏一轮 ≈ 淘宝 4 × 5s 超时 ≈ 20s（北京首轮还要叠 SNTP 2 台 × 2s）。
    /// 取 30s 留出安全边界（Android 端同值）。
    static let stuckMs: Int64 = 30_000
    static let uiTickInterval: TimeInterval = 0.05
    static let httpTimeout: TimeInterval = 5
    /// SNTP 单次超时：蜂窝网封 UDP123 时靠它尽快失败去走 HTTP 兜底
    static let sntpTimeout: TimeInterval = 2

    // 淘宝
    static let taobaoUrl = "https://acs.m.taobao.com/gw/mtop.common.getTimestamp/"

    // 京东：Date 头 + 秒边界交集（api.m.jd.com 响应只有几十字节，实测 rtt 26ms）
    static let jdProbeUrls = ["https://api.m.jd.com/"]
    static let jdProbeSamples = 12
    static let jdProbeGapMs: UInt64 = 45

    // 北京
    static let sntpHosts = ["ntp.aliyun.com", "ntp1.aliyun.com", "ntp2.aliyun.com", "cn.pool.ntp.org"]
    static let sntpHostsPerSample = 2
    static let bjNtpCooldownMs: Int64 = 300_000
    static let bjDateProbeUrls = ["https://www.baidu.com/", "https://www.qq.com/"]
    static let bjDateProbeSamples = 6

    /// rtt 超过这个值的样本直接丢
    static let dateProbeMaxRttMs: Int64 = 300
    /// 单次探针超时：必须短，网络一卡整轮取样会被拖死
    static let dateProbeTimeout: TimeInterval = 3
    /// 一整轮取样的硬预算：到点就用手上的样本收工
    static let jdBurstBudgetMs: Int64 = 4_000
    static let bjBurstBudgetMs: Int64 = 4_500
    /// 调度自愈阈值：超过这么久连"开始校时"都没有过，就强行补一次
    static let selfHealMs: Int64 = 90_000
}

private func hostOf(_ url: String) -> String {
    url.replacingOccurrences(of: "https://", with: "")
        .replacingOccurrences(of: "http://", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

/// 抓一组 Date 头样本并累计进交集器。
/// ★ 整轮有硬预算 budgetMs：到点就用手上的样本收工，绝不恋战
///   （以前没预算，单次超时 5s × 12 次能把一轮拖到一分钟，把校时循环拖死）
private func probeBurst(urls: [String],
                        samplesPerUrl: Int,
                        gapMs: UInt64,
                        budgetMs: Int64,
                        intersector: DateIntersector,
                        headers: [String: String] = [:]) async -> (url: String?, accepted: Int, minRttMs: Int64) {
    let deadline = monoMs() + budgetMs
    var accepted = 0
    /// **本轮**最小 rtt：界面上"往返 Nms"必须反映当前网络，
    /// 不能用交集器里存了十分钟的历史最小值（那会显得比实际更乐观）
    var minRtt: Int64 = -1
    var good: String?
    var outOfTime = false
    for url in urls {
        var ok = 0
        for _ in 0..<samplesPerUrl {
            if monoMs() > deadline {
                outOfTime = true
                break
            }
            if let s = await DateProbe.probe(url, headers: headers), s.rttMs <= Cfg.dateProbeMaxRttMs {
                intersector.add(s, monoNowMs: monoMs())
                ok += 1
                accepted += 1
                if minRtt < 0 || s.rttMs < minRtt { minRtt = s.rttMs }
            }
            try? await Task.sleep(nanoseconds: gapMs * 1_000_000)
        }
        if ok > 0 {
            // ★ 一轮只用一台主机：京东两台走不同边缘（jfe / nginx）、北京兜底是百度/腾讯，
            //   钟能差几十毫秒，混进同一个交集器会夹出"更紧但带系统偏差"的值。
            if good == nil { good = url }
            break
        }
        if outOfTime { break }
    }
    return (good, accepted, minRtt)
}

// MARK: - 北京时间

final class BeijingSource: TimeSource {
    let id = "bj"
    let label = "北京"

    private var hostCursor = 0
    private let intersector = DateIntersector()
    /// 上一轮实际用的探针 URL：用来检测"换了主机"，换了就要清空交集器
    private var lastProbeUrl: String?
    private var ntpDownUntilMono: Int64 = 0
    private var lastModeDateOnly = false
    private var lastHalfWidthMs: Int64 = 30

    var preferredSamples: Int { monoMs() < ntpDownUntilMono ? 1 : Cfg.samplesPerSync }
    var selfAggregated: Bool { monoMs() < ntpDownUntilMono }
    var extraUncertaintyMs: Int64 { lastModeDateOnly ? max(lastHalfWidthMs + 8, 10) : 3 }

    func fetch() async throws -> RawSync {
        // 1) SNTP
        if monoMs() >= ntpDownUntilMono {
            for i in 0..<Cfg.sntpHostsPerSample {
                let host = Cfg.sntpHosts[(hostCursor + i) % Cfg.sntpHosts.count]
                do {
                    let r = try await SntpClient.request(host: host, timeout: Cfg.sntpTimeout)
                    hostCursor += 1
                    lastModeDateOnly = false
                    return RawSync(serverUtcMsAtRecv: r.serverUtcMsAtRecv,
                                   monoMsAtRecv: monoMs(),
                                   rttMs: r.rttMs,
                                   strategy: "SNTP \(host) (stratum \(r.stratum))",
                                   preciseMs: true)
                } catch {
                    // 继续试下一台
                }
            }
            hostCursor += 1
            ntpDownUntilMono = monoMs() + Cfg.bjNtpCooldownMs
        }

        // 2) HTTP Date 头秒边界交集兜底
        // ★ 这里**不能** reset：交集器要跨轮累积才能把区间越收越紧
        //   （设备重启时 DateIntersector 自己会检测单调钟倒退并清空）。
        //   以前每轮都 reset，导致兜底只用当轮 6 个样本，区间偏宽、失败率也高。
        let res = await probeBurst(urls: Cfg.bjDateProbeUrls,
                                   samplesPerUrl: Cfg.bjDateProbeSamples,
                                   gapMs: Cfg.jdProbeGapMs,
                                   budgetMs: Cfg.bjBurstBudgetMs,
                                   intersector: intersector,
                                   // 百度/腾讯首页是几百 KB：加 Range 只取首字节，Date 头照样在，流量省 99%
                                   headers: ["Range": "bytes=0-0"])
        // ★ 本轮一条新样本都没拿到时，绝不能用交集器里的旧约束糊弄成"刚校准"：
        //   旧约束照样能算出 estimate，界面会显示绿色"往返 26ms · 0s前校准"，
        //   而 isStale() 永远不会触发（这是精度最后一道兜底）。
        guard res.accepted > 0 else {
            throw NSError(domain: "TimeFloat", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "NTP 不通，本轮 HTTP Date 兜底 0 个有效样本"])
        }
        if let u = res.url, let last = lastProbeUrl, u != last {
            // 换了主机（百度 ↔ 腾讯）→ 两家约束不能混着求交：清空并作废本轮
            intersector.reset()
            lastProbeUrl = u
            throw NSError(domain: "TimeFloat", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Date 主机切换（\(hostOf(last)) → \(hostOf(u))），本轮作废"])
        }
        if let u = res.url { lastProbeUrl = u }
        guard let est = intersector.estimate() else {
            throw NSError(domain: "TimeFloat", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "NTP 不通，HTTP Date 兜底样本不足（\(res.accepted) 次）"])
        }
        lastModeDateOnly = true
        lastHalfWidthMs = max(est.halfWidthMs, 8)
        let mono = monoMs()
        return RawSync(serverUtcMsAtRecv: mono + est.offsetMs,
                       monoMsAtRecv: mono,
                       rttMs: max(res.minRttMs, 1),
                       strategy: "HTTP Date 秒边界交集 \(hostOf(res.url ?? ""))（\(est.samples) 样本 · ±\(est.halfWidthMs)ms）",
                       preciseMs: true)
    }
}

// MARK: - 淘宝服务器时间

final class TaobaoSource: TimeSource {
    let id = "taobao"
    let label = "淘宝"
    var extraUncertaintyMs: Int64 { 5 }

    func fetch() async throws -> RawSync {
        let url = Cfg.taobaoUrl + "?_=\(Int(Date().timeIntervalSince1970 * 1000))"
        let r = try await Http.get(url, timeout: Cfg.httpTimeout,
                                   headers: ["Referer": "https://m.taobao.com/"])
        guard r.status == 200 else {
            throw NSError(domain: "TimeFloat", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "淘宝 HTTP \(r.status)"])
        }
        let pattern = "\"t\"\\s*:\\s*\"?(\\d{10,13})\"?"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: r.body, range: NSRange(r.body.startIndex..., in: r.body)),
              let range = Range(m.range(at: 1), in: r.body),
              var t = Int64(r.body[range]) else {
            throw NSError(domain: "TimeFloat", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "淘宝响应里没有 t 字段"])
        }
        if t < 1_000_000_000_000 { t *= 1000 }
        let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(t - wallNow) < 86_400_000 else {
            throw NSError(domain: "TimeFloat", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "淘宝返回的时间戳不合理"])
        }
        return RawSync(serverUtcMsAtRecv: t + r.rttMs / 2,
                       monoMsAtRecv: r.monoAtRecvMs,
                       rttMs: r.rttMs,
                       strategy: "mtop.common.getTimestamp",
                       preciseMs: true)
    }
}

// MARK: - 京东服务器时间
//
// 商品页那个 presellInfo.serverTime 字段时有时无（页面从 284KB 缩到 3KB 时直接消失），
// 一旦缺失就会退到秒精度的 Date 头 → 误差 0~1000ms 随机跳。
// 现在统一走：api.m.jd.com 的 Date 头 + 秒边界交集，稳定且几十毫秒级。

final class JdSource: TimeSource {
    let id = "jd"
    let label = "京东"
    var preferredSamples: Int { 1 }
    var selfAggregated: Bool { true }

    private let intersector = DateIntersector()
    private var lastHalfWidthMs: Int64 = 30
    private var goodUrl: String?
    /// 上一轮实际用的探针 URL（换主机时要清空交集器）
    private var lastProbeUrl: String?

    var extraUncertaintyMs: Int64 { max(lastHalfWidthMs + 8, 10) }

    func fetch() async throws -> RawSync {
        var urls = Cfg.jdProbeUrls
        if let g = goodUrl, !urls.contains(g) { urls.insert(g, at: 0) }

        let res = await probeBurst(urls: urls,
                                   samplesPerUrl: Cfg.jdProbeSamples,
                                   gapMs: Cfg.jdProbeGapMs,
                                   budgetMs: Cfg.jdBurstBudgetMs,
                                   intersector: intersector,
                                   headers: ["Referer": "https://www.jd.com/"])
        if let g = res.url { goodUrl = g }

        // ★ 本轮零新样本时不许拿旧约束冒充"刚校准"（同北京兜底那条）
        guard res.accepted > 0 else {
            throw NSError(domain: "TimeFloat", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "京东本轮 0 个有效 Date 样本"])
        }
        if let u = res.url, let last = lastProbeUrl, u != last {
            // 换了主机（jfe ↔ nginx）→ 清空交集器并作废本轮，别把两家的约束混着求交
            intersector.reset()
            lastProbeUrl = u
            throw NSError(domain: "TimeFloat", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "京东 Date 主机切换（\(hostOf(last)) → \(hostOf(u))），本轮作废"])
        }
        if let u = res.url { lastProbeUrl = u }

        guard let est = intersector.estimate() else {
            throw NSError(domain: "TimeFloat", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "京东 Date 头样本不足（本轮有效 \(res.accepted) 次）"])
        }
        lastHalfWidthMs = max(est.halfWidthMs, 8)
        let mono = monoMs()
        return RawSync(serverUtcMsAtRecv: mono + est.offsetMs,
                       monoMsAtRecv: mono,
                       rttMs: max(res.minRttMs, 1),
                       strategy: "Date 秒边界交集 \(hostOf(res.url ?? ""))（\(est.samples) 样本 · ±\(est.halfWidthMs)ms）",
                       preciseMs: true)
    }
}
