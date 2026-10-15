import Foundation
import Network

/// 手写 SNTP 客户端（Network.framework 的 UDP）。
/// 返回的 serverUtcMsAtRecv 已经做掉 rtt/2 补偿，含义是
/// 「在单调时钟 monoMsAtRecv 这一刻，服务器时钟显示的值」。
enum SntpClient {
    private static let ntpEpochDiff: Int64 = 2_208_988_800

    struct Reply {
        let serverUtcMsAtRecv: Int64
        let rttMs: Int64
        let stratum: Int
        let host: String
    }

    enum SntpError: Error { case timeout, badPacket, connect(String) }

    static func request(host: String, timeout: TimeInterval = Cfg.sntpTimeout) async throws -> Reply {
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0x1B                      // LI=0, VN=3, Mode=3 (client)

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 123, using: .udp)
        let queue = DispatchQueue(label: "timefloat.sntp")
        let t0 = monoMs()

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            let lock = NSLock()

            func finish(_ r: Result<Reply, Error>) {
                lock.lock()
                defer { lock.unlock() }
                if finished { return }
                finished = true
                conn.cancel()
                cont.resume(with: r)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(packet), completion: .contentProcessed { err in
                        if let err = err { finish(.failure(err)); return }
                        conn.receiveMessage { data, _, _, err in
                            let t1 = monoMs()
                            if let err = err { finish(.failure(err)); return }
                            guard let data = data, data.count >= 48 else {
                                finish(.failure(SntpError.badPacket)); return
                            }
                            let b = [UInt8](data)
                            let sec = u32(b, 40)
                            let frac = u32(b, 44)
                            let ms = (sec - ntpEpochDiff) * 1000 + (frac * 1000) / 4_294_967_296
                            let rtt = t1 - t0
                            finish(.success(Reply(serverUtcMsAtRecv: ms + rtt / 2,
                                                  rttMs: rtt,
                                                  stratum: Int(b[1]),
                                                  host: host)))
                        }
                    })
                case .failed(let e):
                    finish(.failure(SntpError.connect("\(e)")))
                case .cancelled:
                    finish(.failure(SntpError.connect("cancelled")))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(SntpError.timeout))
            }
        }
    }

    private static func u32(_ b: [UInt8], _ off: Int) -> Int64 {
        (Int64(b[off]) << 24) | (Int64(b[off + 1]) << 16) | (Int64(b[off + 2]) << 8) | Int64(b[off + 3])
    }
}
