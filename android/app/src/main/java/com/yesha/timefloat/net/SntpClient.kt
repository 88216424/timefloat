package com.yesha.timefloat.net

import com.yesha.timefloat.Config
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress

/**
 * 手写 SNTP 客户端（RFC 4330 简化版，客户端模式 + 单次请求）。
 *
 * 关键点：用 t4（本地收到回包的瞬间）来对齐，再返回 rtt，让上层做 rtt/2 补偿：
 *   serverAtRecv = transmitTimestamp + rtt/2
 * 这就是 NTP 里最常用的假设——请求和响应路径耗时对称。
 * 采样多次后取 rtt 最小的那几次，可以把这个假设的误差压到 ±10ms 以内。
 */
object SntpClient {

    private const val NTP_EPOCH_DIFF_S = 2_208_988_800L
    private const val PORT = 123

    data class Reply(val serverUtcMsAtRecv: Long, val rttMs: Long, val stratum: Int, val refId: String)

    fun request(host: String, timeoutMs: Int = Config.SNTP_TIMEOUT_MS): Reply {
        val socket = DatagramSocket()
        try {
            socket.soTimeout = timeoutMs
            socket.reuseAddress = true
            val addr = InetAddress.getByName(host)
            val buf = ByteArray(48)
            buf[0] = 0x1B                     // LI=0, VN=3, Mode=3(client)
            val packet = DatagramPacket(buf, buf.size, InetSocketAddress(addr, PORT))

            val sendMono = System.nanoTime()
            socket.send(packet)

            val recv = DatagramPacket(ByteArray(512), 512)
            socket.receive(recv)
            val recvMono = System.nanoTime()

            val data = recv.data
            if (recv.length < 48) throw IllegalStateException("NTP 回包过短: ${recv.length}")
            val stratum = data[1].toInt() and 0xFF
            val refId = String(data, 12, 4, Charsets.US_ASCII).trim { it <= ' ' || it == '\u0000' }

            // Transmit Timestamp 在 40..47（秒 + 小数部分，均大端）
            val sec = u32(data, 40)
            val frac = u32(data, 44)
            val serverMs = (sec - NTP_EPOCH_DIFF_S) * 1000L + (frac * 1000L) / 4_294_967_296L
            val rttMs = (recvMono - sendMono) / 1_000_000

            return Reply(serverMs + rttMs / 2, rttMs, stratum, refId)
        } finally {
            socket.close()
        }
    }

    private fun u32(b: ByteArray, off: Int): Long =
        ((b[off].toLong() and 0xFF) shl 24) or
            ((b[off + 1].toLong() and 0xFF) shl 16) or
            ((b[off + 2].toLong() and 0xFF) shl 8) or
            (b[off + 3].toLong() and 0xFF)
}
