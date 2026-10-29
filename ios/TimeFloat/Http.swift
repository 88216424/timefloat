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
                    headers: [String: String] = [:],
                    /// ★ 响应体硬上限（与 Android 端 256KB 对齐）。
                    ///   URLSession 的 `timeoutInterval` 只是"两个数据包之间的空闲超时"，
                    ///   服务器只要每 <5 秒吐一点数据，`data(for:)` 就能无限下载下去。
                    ///   校时实际只需要几十字节（淘宝的 t 字段），超限直接判失败换源。
                    maxBytes: Int = 256 * 1024) async throws -> HttpResult {
        guard let u = URL(string: url) else { throw NSError(domain: "TimeFloat", code: -1) }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let t0 = monoMs()
        let (stream, resp) = try await URLSession.shared.bytes(for: req)
        var data = Data()
        data.reserveCapacity(4096)
        for try await byte in stream {
            data.append(byte)
            if data.count > maxBytes {
                stream.task.cancel()
                throw NSError(domain: "TimeFloat", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "响应体超过 \(maxBytes / 1024)KB，已放弃"])
            }
        }
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
