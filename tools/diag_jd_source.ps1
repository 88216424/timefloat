# 京东时间源实测诊断 v2
#   A) 老方法：抓 item 页 serverTime（SSR 页面）
#   B) 新方法：api.m.jd.com 的 HTTP Date 头 + 多次采样「秒边界交集」
# 基准：NTP(ntp.aliyun.com)、淘宝 getTimestamp

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Net.Http

$UA = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36'
$SW = [Diagnostics.Stopwatch]::StartNew()
$HC = [System.Net.Http.HttpClient]::new()
$HC.Timeout = [TimeSpan]::FromSeconds(10)
$HC.DefaultRequestHeaders.Add('User-Agent', $UA)

function NowMono { return $SW.Elapsed.TotalMilliseconds }

function NtpOffset {
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 3000
        $udp.Connect('ntp.aliyun.com', 123)
        $pkt = New-Object byte[] 48; $pkt[0] = 0x1B
        $sendM = NowMono
        $null = $udp.Send($pkt, 48)
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        $recvM = NowMono
        $sec = ([uint32]$resp[40] -shl 24) -bor ([uint32]$resp[41] -shl 16) -bor ([uint32]$resp[42] -shl 8) -bor [uint32]$resp[43]
        $frac = ([uint32]$resp[44] -shl 24) -bor ([uint32]$resp[45] -shl 16) -bor ([uint32]$resp[46] -shl 8) -bor [uint32]$resp[47]
        $serverMs = ([int64]$sec - 2208988800L) * 1000L + [int64]($frac * 1000L / 4294967296L)
        $rtt = $recvM - $sendM
        return @{ off = $serverMs + $rtt / 2 - $recvM; rtt = $rtt }
    } finally { $udp.Close() }
}

function TaobaoOffset {
    $u = 'https://acs.m.taobao.com/gw/mtop.common.getTimestamp/?_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $t0 = NowMono
    $r = $HC.GetStringAsync($u).GetAwaiter().GetResult()
    $t1 = NowMono
    $m = [regex]::Match($r, '"t"\s*:\s*"?(\d{13})"?')
    if (-not $m.Success) { return @{ off = $null; rtt = 0 } }
    $t = [int64]$m.Groups[1].Value
    $rtt = $t1 - $t0
    return @{ off = $t + $rtt / 2 - $t1; rtt = $rtt }
}

function DateMsOf($resp) {
    $vals = $null
    if (-not $resp.Headers.TryGetValues('Date', [ref]$vals)) { return $null }
    $s = ($vals | Select-Object -First 1)
    if (-not $s) { return $null }
    try {
        $dto = [DateTimeOffset]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)
        return $dto.ToUnixTimeMilliseconds()
    } catch {
        return $null
    }
}

$ntp = NtpOffset
$tb = TaobaoOffset
Write-Host ("基准：NTP rtt={0:N0}ms | 淘宝 rtt={1:N0}ms" -f $ntp.rtt, $tb.rtt)
Write-Host ("基准偏移差（淘宝 - NTP）= {0:N0}ms" -f ($tb.off - $ntp.off))
Write-Host ""

Write-Host "===== A) item 页 serverTime 是否还在（这是老方法唯一的毫秒来源） ====="
foreach ($sku in @('100012043978', '100012043978', '100026667910', '100015547940', '100020389273')) {
    $u = "https://item.m.jd.com/product/$sku.html"
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $HC.GetAsync($u, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $ttfb = $sw2.Elapsed.TotalMilliseconds
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buf = New-Object byte[] 16384
        $acc = New-Object System.Text.StringBuilder
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $null = $acc.Append([Text.Encoding]::UTF8.GetString($buf, 0, $n))
            if ($acc.Length -gt 400000) { break }
        }
        $body = $acc.ToString()
        $hit = [regex]::Match($body, '"serverTime"\s*:\s*"?(?<v>\d{13})"?')
        $hasPresell = $body.Contains('presellInfo')
        if ($hit.Success) {
            $t = [int64]$hit.Groups['v'].Value
            $dateMs = DateMsOf $resp
            Write-Host ("  SKU {0}  TTFB {1,5:N0}ms  读到 {2,6:N0}KB  serverTime={3}  presellInfo={4}" -f $sku, $ttfb, ($body.Length / 1024), $t, $hasPresell)
        } else {
            Write-Host ("  SKU {0}  TTFB {1,5:N0}ms  读到 {2,6:N0}KB  **没有 serverTime**  presellInfo={3}" -f $sku, $ttfb, ($body.Length / 1024), $hasPresell)
        }
    } catch {
        Write-Host ("  SKU {0}  ERR {1}" -f $sku, $_.Exception.Message)
    }
}

Write-Host ""
Write-Host "===== B) 新方法：Date 头秒边界交集（16 次采样） ====="
$lo = -1e18; $hi = 1e18; $n = 0; $vLo = @(); $rtts = @()
for ($i = 0; $i -lt 16; $i++) {
    $t0 = NowMono
    try {
        $r = $HC.GetAsync('https://api.m.jd.com/').GetAwaiter().GetResult()
        $t1 = NowMono
        $dateMs = DateMsOf $r
        if ($dateMs) {
            $rtt = $t1 - $t0
            $v = $dateMs - ($t1 - $rtt / 2)
            $vLo += $v; $rtts += $rtt
            if ($v -gt $lo) { $lo = $v }
            if ($v + 1000 -lt $hi) { $hi = $v + 1000 }
            $n++
        }
    } catch { }
    Start-Sleep -Milliseconds 50
}
if ($n -ge 2) {
    $mid = ($lo + $hi) / 2
    Write-Host ("  样本={0}  交集宽度={1:N0}ms  中点偏移={2:N0}ms" -f $n, ($hi - $lo), $mid)
    Write-Host ("  相对NTP = {0:N0}ms    相对淘宝 = {1:N0}ms" -f ($mid - $ntp.off), ($mid - $tb.off))
    Write-Host ("  平均RTT {0:N0}ms  各样本下界极差 {1:N0}ms（越大说明秒边界覆盖越全）" -f (($rtts | Measure-Object -Average).Average), (($vLo | Measure-Object -Maximum).Maximum - ($vLo | Measure-Object -Minimum).Minimum))
} else {
    Write-Host ("  可用样本不足（{0}）—— Date 头拿不到" -f $n)
}

Write-Host ""
Write-Host "===== C) 再跑一轮，看稳定性 ====="
$ntp2 = NtpOffset
$lo = -1e18; $hi = 1e18; $n = 0
for ($i = 0; $i -lt 16; $i++) {
    $t0 = NowMono
    try {
        $r = $HC.GetAsync('https://api.m.jd.com/').GetAwaiter().GetResult()
        $t1 = NowMono
        $dateMs = DateMsOf $r
        if ($dateMs) {
            $rtt = $t1 - $t0
            $v = $dateMs - ($t1 - $rtt / 2)
            if ($v -gt $lo) { $lo = $v }
            if ($v + 1000 -lt $hi) { $hi = $v + 1000 }
            $n++
        }
    } catch { }
    Start-Sleep -Milliseconds 50
}
if ($n -ge 2) {
    $mid2 = ($lo + $hi) / 2
    Write-Host ("  样本={0}  交集宽度={1:N0}ms  中点相对NTP={2:N0}ms" -f $n, ($hi - $lo), ($mid2 - $ntp2.off))
    $tb2 = TaobaoOffset
    Write-Host ("  与淘宝差={0:N0}ms" -f ($mid2 - $tb2.off))
} else {
    Write-Host "  样本不足"
}
