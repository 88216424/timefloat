#!/usr/bin/env bash
# 三个时间源实测探针（macOS / Linux，打包 iOS 之前先跑一遍）
# 用法：bash tools/check_sources.sh
set -u

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

beijing=""
for h in ntp.aliyun.com ntp1.aliyun.com cn.pool.ntp.org time.windows.com; do
  r=$(python3 - "$h" <<'PY' 2>/dev/null
import socket, struct, sys, time
host = sys.argv[1]
pkt = b'\x1b' + 47 * b'\x00'
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(4)
    t0 = time.time()
    s.sendto(pkt, (host, 123))
    data, _ = s.recvfrom(512)
    t1 = time.time()
    sec, frac = struct.unpack('!II', data[40:48])
    ms = int((sec - 2208988800) * 1000 + frac * 1000 / 2**32)
    rtt = int((t1 - t0) * 1000)
    print(f"{ms} {rtt} {data[1]}")
except Exception as e:
    sys.exit(1)
PY
)
  if [ -n "$r" ]; then
    set -- $r
    echo "[OK  ] SNTP $h  server=$1  rtt=${2}ms  stratum=$3"
    beijing=$1
    break
  else
    echo "[FAIL] SNTP $h"
  fi
done

echo "--- 淘宝 ---"
TB=$(curl -s -m 8 -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" \
     "https://acs.m.taobao.com/gw/mtop.common.getTimestamp/?_=$(now_ms)")
echo "$TB" | head -c 200; echo
echo "--- 京东（预约商品页 serverTime，毫秒）---"
for sku in 100012043978 100026667910 100015547940; do
  body=$(curl -s -m 12 -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" \
         -H "Referer: https://item.jd.com/" "https://item.m.jd.com/product/${sku}.html" | head -c 400000)
  hit=$(printf '%s' "$body" | grep -o '"serverTime":[0-9]\{13\}' | head -1)
  if [ -n "$hit" ]; then
    t=${hit#*:}
    echo "[OK  ] JD SKU $sku  $hit  skew_local=$((t - $(now_ms)))ms"
    break
  else
    echo "[WARN] JD SKU $sku 没有 serverTime 字段（该 SKU 不是预约/抢购页）"
  fi
done
echo "--- 京东兜底：HTTP Date 头 ---"
curl -s -m 8 -o /dev/null -D - -A "Mozilla/5.0" https://api.m.jd.com/ | grep -i '^date:'
echo "--- 北京时间兜底：HTTP Date 头 ---"
curl -s -m 8 -o /dev/null -D - -A "Mozilla/5.0" https://www.baidu.com/ | grep -i '^date:'
echo "本机墙钟：$(date '+%Y-%m-%d %H:%M:%S')"
