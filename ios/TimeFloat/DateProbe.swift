import Foundation

/// 一次 HTTP `Date` 头采样
struct DateSample {
    /// 偏移量下界：服务器UTC - 本地单调毫秒
    let lowerBoundOffsetMs: Int64
    /// 模型误差余量：路径不对称带来的不确定度，取 rtt/2 + 5
    let marginMs: Int64
    let dateMs: Int64
    let rttMs: Int64
    let monoAtRecvMs: Int64
}

/// 只取响应头的极轻量探针（不读 body）
enum DateProbe {
    static func probe(_ url: String,
                      timeout: TimeInterval = Cfg.dateProbeTimeout,
                      headers: [String: String] = [:]) async -> DateSample? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue(Http.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // ★ 只要 Date 头，body 一个字节都不要。
        //   URLSession.bytes(for:) 返回的 AsyncBytes 我们从不消费也从不取消，
        //   不加 Range 的话每轮会把百度/腾讯首页（各几百 KB）在后台整个拖下来 ——
        //   移动网络下是实打实的白耗流量。Range 响应只有 1 字节，Date 头照样有效。
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let t0 = monoMs()
        do {
            // bytes(for:) 在响应头到齐时就返回，不会等 body —— 和 Android 端只取响应头等价
            let (stream, resp) = try await URLSession.shared.bytes(for: req)
            let t1 = monoMs()
            // 只要响应头，body 一个字节都不要：这里直接把任务取消掉
            // （以前写的是 `defer { _ = stream }`，等于什么都不做，任务自己要等 body 收完）
            defer { stream.task.cancel() }
            guard let http = resp as? HTTPURLResponse, (200...499).contains(http.statusCode) else { return nil }
            guard let raw = http.value(forHTTPHeaderField: "Date"), let d = Http.parseHttpDate(raw) else { return nil }
            let dateMs = Int64(d.timeIntervalSince1970 * 1000)
            let rtt = t1 - t0
            // L = 服务器生成该响应时的本地单调时刻 ≈ 收到响应头时刻 - 单程时延
            let l = t1 - rtt / 2
            return DateSample(lowerBoundOffsetMs: dateMs - l,
                              marginMs: rtt / 2 + 5,
                              dateMs: dateMs,
                              rttMs: rtt,
                              monoAtRecvMs: t1)
        } catch {
            return nil
        }
    }
}

/// 秒边界交集估计器：把只有「秒」精度的 Date 头夹逼成几十毫秒精度的时钟。
///
/// 每次采样给出一条约束：  dateMs ≤ 本地单调L + 偏移量 < dateMs + 1000
/// 令 v = dateMs - L，则 偏移量 ∈ [v - margin, v + 1000 + margin)。
/// 多次采样的「秒内相位」不同，求交集后区间宽度 = 1000 + 2m - 相位跨度，
/// 相位铺满一整秒时收敛到 2m —— 对 rtt 26ms 的 api.m.jd.com 约 ±25ms。
final class DateIntersector {
    private struct Constraint { let v: Int64; let margin: Int64 }

    private var list: [Constraint] = []
    private let window: Int
    private var lastMonoMs: Int64 = 0
    private(set) var lastMinRttMs: Int64 = -1

    init(window: Int = 28) { self.window = window }

    func add(_ s: DateSample, monoNowMs: Int64) {
        if lastMonoMs != 0 && monoNowMs < lastMonoMs { list.removeAll() }   // 单调钟倒退 = 重启
        lastMonoMs = monoNowMs
        list.append(Constraint(v: s.lowerBoundOffsetMs, margin: s.marginMs))
        if list.count > window { list.removeFirst() }
        if lastMinRttMs < 0 || s.rttMs < lastMinRttMs { lastMinRttMs = s.rttMs }
    }

    func estimate() -> (offsetMs: Int64, halfWidthMs: Int64, samples: Int)? {
        guard list.count >= 6 else { return nil }
        var lo = Int64.min
        var hi = Int64.max
        for c in list {
            lo = max(lo, c.v - c.margin)
            hi = min(hi, c.v + 1000 + c.margin)
        }
        guard hi > lo else {                 // 约束矛盾：本机时钟被改过？丢掉重来
            list.removeAll()
            lastMinRttMs = -1
            return nil
        }
        return ((lo + hi) / 2, (hi - lo) / 2, list.count)
    }

    func reset() {
        list.removeAll()
        lastMinRttMs = -1
    }
}
