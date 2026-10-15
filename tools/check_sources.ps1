# 三个时间源实测探针（Windows / PowerShell 7）
# 用途：在打包 App 之前，先确认本机网络能拿到 淘宝 / 京东 / 北京时间 的服务器时间。
# 运行：pwsh -ExecutionPolicy Bypass -File tools/check_sources.ps1

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Show($tag, $name, $info) {
    Write-Host ("[{0}] {1,-28} {2}" -f $tag, $name, $info)
}

function U32BE($b, $o) {
    return ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o + 1] -shl 16) -bor ([uint32]$b[$o + 2] -shl 8) -bor [uint32]$b[$o + 3]
}

function LocalNowMs { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# ---------- 1. 北京时间：SNTP ----------
function SntpProbe($server) {
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 4000
        $udp.Client.SendTimeout = 4000
        $udp.Connect($server, 123)
        $pkt = New-Object byte[] 48
        $pkt[0] = 0x1B                      # LI=0 VN=3 Mode=3 (client)
        $shot = [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()
        $null = $udp.Send($pkt, 48)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        $sw.Stop()
        if ($resp.Length -lt 48) { throw 'NTP 回包长度不足' }
        $sec = U32BE $resp 40               # Transmit Timestamp seconds
        $frac = U32BE $resp 44
        $ms = ([int64]$sec - 2208988800L) * 1000L + [int64](($frac * 1000L) / 4294967296L)
        $rtt = $sw.ElapsedMilliseconds
        $vendor = [System.Text.Encoding]::ASCII.GetString($resp, 12, 4).Trim([char]0)
        return @{ ms = $ms; rtt = $rtt; vendor = $vendor; stratum = $resp[1] }
    }
    finally { $udp.Close() }
}

foreach ($h in @('ntp.aliyun.com', 'ntp1.aliyun.com', 'cn.pool.ntp.org', 'time.windows.com')) {
    try {
        $r = SntpProbe $h
        $skew = $r.ms - (LocalNowMs)
        Show 'OK  ' "NTP $h" ("server={0}  skew_local={1}ms  rtt={2}ms  stratum={3}" -f $r.ms, $skew, $r.rtt, $r.stratum)
    }
    catch {
        Show 'FAIL' "NTP $h" $_.Exception.Message
    }
}

# ---------- 2. 淘宝服务器时间 ----------
$taobaoUrls = @(
    'https://acs.m.taobao.com/gw/mtop.common.getTimestamp/',
    'http://api.m.taobao.com/rest/api3.do?api=mtop.common.getTimestamp'
)
foreach ($u in $taobaoUrls) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $u -TimeoutSec 8 -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36' }
        $sw.Stop()
        $m = [regex]::Match($r.Content, '"t"\s*:\s*"?(\d{10,13})"?')
        if ($m.Success) {
            $t = [int64]$m.Groups[1].Value
            if ($t -lt 1000000000000L) { $t = $t * 1000L }   # 秒 -> 毫秒
            $skew = $t - (LocalNowMs)
            Show 'OK  ' "Taobao $([uri]$u | Select-Object -ExpandProperty Host)" ("server={0}  skew_local={1}ms  rtt={2}ms" -f $t, $skew, $sw.ElapsedMilliseconds)
        }
        else {
            $body = $r.Content; if ($body.Length -gt 160) { $body = $body.Substring(0, 160) }
            Show 'WARN' "Taobao $u" ("HTTP 通但未解析到 t 字段：{0}" -f ($body -replace '\s+', ' '))
        }
    }
    catch {
        $sw.Stop()
        Show 'FAIL' "Taobao $u" $_.Exception.Message
    }
}

# ---------- 3. 京东服务器时间 ----------
$jdUrls = @(
    'https://a.jd.com/ajax/queryServerData.html',
    'https://api.m.jd.com/client.action?functionId=queryServerTime'
)
foreach ($u in $jdUrls) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $u -TimeoutSec 8 -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36'; 'Referer' = 'https://a.jd.com/' }
        $sw.Stop()
        $m = [regex]::Match($r.Content, '(?:serverTime|server_time|"t"|time)\D{0,4}(\d{10,13})')
        if ($m.Success) {
            $t = [int64]$m.Groups[1].Value
            if ($t -lt 1000000000000L) { $t = $t * 1000L }
            $skew = $t - (LocalNowMs)
            Show 'OK  ' "JD $([uri]$u | Select-Object -ExpandProperty Host)" ("server={0}  skew_local={1}ms  rtt={2}ms" -f $t, $skew, $sw.ElapsedMilliseconds)
        }
        else {
            $body = $r.Content; if ($body.Length -gt 160) { $body = $body.Substring(0, 160) }
            Show 'WARN' "JD $u" ("HTTP 通但未解析到时间字段：{0}" -f ($body -replace '\s+', ' '))
        }
    }
    catch {
        $sw.Stop()
        Show 'FAIL' "JD $u" $_.Exception.Message
    }
}

# ---------- 4. 兜底源：HTTP Date 响应头（百度） ----------
foreach ($u in @('https://www.baidu.com/', 'https://www.taobao.com/')) {
    try {
        $r = Invoke-WebRequest -Uri $u -TimeoutSec 8 -UseBasicParsing -Method Head
        $d = [datetime]::Parse($r.Headers['Date'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        $ms = [DateTimeOffset]::new($d).ToUnixTimeMilliseconds()
        Show 'OK  ' "Date header $([uri]$u | Select-Object -ExpandProperty Host)" ("server={0}  skew_local={1}ms" -f $ms, ($ms - (LocalNowMs)))
    }
    catch {
        Show 'FAIL' "Date header $u" $_.Exception.Message
    }
}

Write-Host ''
Show 'INFO' '本机墙钟' ([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'))
