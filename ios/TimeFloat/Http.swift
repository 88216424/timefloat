import Foundation

struct HttpResult {
    let status: Int
    let body: String
    /// 读完响应体那一刻的单调毫秒（用于对齐服务器时间戳，不是墙钟）
    let monoAtRecvMs: Int64
    /// Date 响应头的 UTC 毫秒（只有秒精度），-1 表示不可用
    let dateHeaderUtcMs: Int64
    let rttMs: Int64
    let bytes: Int
}

/// 极简 HTTP 客户端。和 Android 端保持同一套精度策略：
/// 单调时钟量 rtt，读完即刻采样，Date 头当秒级兜底源。
enum Http {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static let httpDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
    private static let httpDateLock = NSLock()

    static func parseHttpDate(_ raw: String) -> Date? {
        httpDateLock.lock()
        defer { httpDateLock.unlock() }
        return httpDateFmt.date(from: raw)
    }

    static func get(_ url: String,
                    timeout: TimeInterval = Cfg.httpTimeout,
                    headers: [String: String] = [:]) async throws -> HttpResult {
        guard let u = URL(string: url) else { throw NSError(domain: "TimeFloat", code: -1) }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let t0 = monoMs()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let t1 = monoMs()
        let http = resp as? HTTPURLResponse
        let body = String(data: data, encoding: .utf8) ?? ""
        var dateMs: Int64 = -1
        if let raw = http?.value(forHTTPHeaderField: "Date"),
           let d = parseHttpDate(raw) {
            dateMs = Int64(d.timeIntervalSince1970 * 1000)
        }
        return HttpResult(status: http?.statusCode ?? 0,
                          body: body,
                          monoAtRecvMs: t1,
                          dateHeaderUtcMs: dateMs,
                          rttMs: t1 - t0,
                          bytes: data.count)
    }
}
