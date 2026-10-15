import Foundation

/// 单调时钟。抢购场景绝不能用墙上时钟做计时基准：系统后台校时一跳就是几百毫秒。
/// DispatchTime 基于 mach 时钟，只单调递增。
@inline(__always) func monoMs() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

enum Fmt {
    static let tzOffsetMs: Int64 = 8 * 3600_000
    private static let dayMs: Int64 = 86_400_000
    private static let week = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// UTC 毫秒 -> 北京时间 HH:mm:ss.SSS
    static func hms(_ utcMs: Int64) -> String {
        var ms = utcMs + tzOffsetMs
        ms = ((ms % dayMs) + dayMs) % dayMs
        let h = ms / 3_600_000
        let mi = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let f = ms % 1000
        return String(format: "%02lld:%02lld:%02lld.%03lld", h, mi, s, f)
    }

    static func hms8(_ utcMs: Int64) -> String { String(hms(utcMs).prefix(8)) }

    static func dateCn(_ utcMs: Int64) -> String {
        let days = floorDiv(utcMs + tzOffsetMs, dayMs)
        let dow = ((days + 4) % 7 + 7) % 7
        let (_, m, d) = ymd(days)
        return String(format: "%02lld-%02lld %@", m, d, week[Int(dow)])
    }

    static func delta(_ ms: Int64) -> String { (ms >= 0 ? "+" : "") + String(ms) }

    /// 倒计时：-01:23.456 / +00:00.312
    static func countdown(_ ms: Int64) -> String {
        let neg = ms < 0
        var v = abs(ms)
        let h = v / 3_600_000; v %= 3_600_000
        let mi = v / 60_000; v %= 60_000
        let s = v / 1000; let f = v % 1000
        return String(format: "%@%02lld:%02lld:%02lld.%03lld", neg ? "-" : "+", h, mi, s, f)
    }

    /// 解析 "20:00:00.000" 成「今天」对应的 UTC 毫秒
    static func parseHms(_ text: String, nowUtcMs: Int64) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":")
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let secPart = parts.count >= 3 ? String(parts[2]) : "0"
        let secSplit = secPart.split(separator: ".", omittingEmptySubsequences: false)
        guard let h = Int64(parts[0]), let mi = Int64(parts[1]),
              let s = Int64(secSplit[0]), h <= 23, mi <= 59, s <= 59 else { return nil }
        var msPart: Int64 = 0
        if secSplit.count > 1 {
            let frac = String(secSplit[1])
            let padded = frac.padding(toLength: 3, withPad: "0", startingAt: 0)
            msPart = Int64(padded.prefix(3)) ?? 0
        }
        let todayLocal = floorDiv(nowUtcMs + tzOffsetMs, dayMs) * dayMs
        let local = todayLocal + h * 3_600_000 + mi * 60_000 + s * 1000 + msPart
        return local - tzOffsetMs
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func ymd(_ daysSinceEpoch: Int64) -> (Int64, Int64, Int64) {
        let z = daysSinceEpoch + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
