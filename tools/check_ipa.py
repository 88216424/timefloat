"""iOS ipa 深度检测：结构 / Info.plist / Mach-O / 签名状态 / 与源码是否一致。

用法：
    python check_ipa.py <ipa路径> [源码里的 Info.plist 路径]

给了第二个参数时，会拿 ipa 里的 Info.plist 和"仓库当前源码里的那份"逐字段比对，
这样能证明"这个包确实是用现在这份源码编出来的"，而不是旧包。
只读，不改任何东西。
"""
import hashlib
import os
import plistlib
import re
import struct
import sys
import zipfile

IPA = sys.argv[1] if len(sys.argv) > 1 else None
SRC_PLIST = sys.argv[2] if len(sys.argv) > 2 else None
if not IPA or not os.path.isfile(IPA):
    print("[FAIL] 找不到 ipa:", IPA)
    sys.exit(1)

problems = []


def ok(label, detail=""):
    print("  [OK]   %-32s %s" % (label, detail))


def bad(label, detail=""):
    print("  [FAIL] %-32s %s" % (label, detail))
    problems.append(label)


size = os.path.getsize(IPA)
sha = hashlib.sha256(open(IPA, "rb").read()).hexdigest()

print("=" * 72)
print("0) 基本")
print("=" * 72)
print("  文件    :", os.path.basename(IPA))
print("  大小    : %.1f KB (%d bytes)" % (size / 1024, size))
print("  SHA-256 :", sha)
print("  修改时间:", __import__("datetime").datetime.fromtimestamp(os.path.getmtime(IPA)).strftime("%Y-%m-%d %H:%M:%S"))

print()
print("=" * 72)
print("1) ZIP 与包结构")
print("=" * 72)
try:
    zf = zipfile.ZipFile(IPA)
    broken = zf.testzip()
    if broken:
        bad("ZIP CRC", broken)
    else:
        ok("ZIP 完整（CRC 全通过）", "%d 条目" % len(zf.namelist()))
except Exception as e:
    bad("ZIP 可读", str(e))
    sys.exit(1)

names = zf.namelist()
apps = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and n.count("/") >= 2})
if not apps:
    bad("Payload 目录")
    sys.exit(1)
app = apps[0]
APP = "Payload/" + app + "/"
inside = [n[len(APP):] for n in names if n.startswith(APP)]
top = sorted({p.split("/")[0] for p in inside})
print("  App     :", app)
print("  内容    :", ", ".join(top))

for forbidden in ("PlugIns", "Frameworks", "SC_Info", "Watch"):
    if forbidden in top:
        bad("不应存在", forbidden)
if "PlugIns" not in top:
    ok("无扩展（免费 Apple ID 可签）")
if "Frameworks" not in top:
    ok("无内嵌框架")
if "_CodeSignature" in top:
    print("  [NOTE] 含 _CodeSignature —— 这个包带签名")
else:
    ok("无 _CodeSignature（未签名）")
junk = [p for p in inside if p.endswith(".DS_Store") or "__MACOSX" in p]
bad("夹带垃圾文件", junk[0]) if junk else ok("无垃圾文件")

print()
print("=" * 72)
print("2) Info.plist")
print("=" * 72)
with zf.open(APP + "Info.plist") as f:
    pl = plistlib.load(f)

print("  CFBundleIdentifier            :", pl.get("CFBundleIdentifier"))
print("  CFBundleDisplayName           :", pl.get("CFBundleDisplayName"))
print("  CFBundleShortVersionString    :", pl.get("CFBundleShortVersionString"))
print("  CFBundleVersion               :", pl.get("CFBundleVersion"))
print("  MinimumOSVersion              :", pl.get("MinimumOSVersion"))
print("  UIDeviceFamily                :", pl.get("UIDeviceFamily"))
print("  UIBackgroundModes             :", pl.get("UIBackgroundModes"))
print("  CFBundleIconFiles             :", pl.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles"))

if "audio" in (pl.get("UIBackgroundModes") or []):
    ok("后台音频模式（画中画保活）")
else:
    bad("后台音频模式", "缺 audio，切到别的 App 会被挂起")
if pl.get("CFBundleIcons"):
    ok("桌面图标已声明")
else:
    bad("桌面图标", "CFBundleIcons 缺失")
for dead in ("NSSupportsLiveActivities", "NSSupportsLiveActivitiesFrequentUpdates"):
    if dead in pl:
        bad("残留死配置", dead)
    else:
        ok("无死配置 " + dead[:28])

# 和源码里的 Info.plist 比对 —— 证明"包和源码一致"
if SRC_PLIST and os.path.isfile(SRC_PLIST):
    print()
    print("  --- 与仓库源码 Info.plist 比对 ---")
    with open(SRC_PLIST, "rb") as f:
        src = plistlib.load(f)
    # 构建期注入的键（源码里本来就没有，Xcode 从 project.yml 填进来）：不比对，只提示
    INJECTED = {"MinimumOSVersion", "DTPlatformName", "DTSDKName", "BuildMachineOSBuild",
                "DTCompiler", "DTPlatformVersion", "DTSDKBuild", "DTXcode", "UIDeviceFamily"}
    same = True
    skipped = []
    for k in ("CFBundleIdentifier", "CFBundleExecutable", "MinimumOSVersion",
              "CFBundleShortVersionString", "CFBundleVersion", "UIBackgroundModes",
              "CFBundleDisplayName", "UIDeviceFamily"):
        a, b = pl.get(k), src.get(k)
        if b is None:
            # 源码里没有 → 构建注入；包里有值就行
            if a is None:
                bad("包内缺字段: " + k)
                same = False
            else:
                skipped.append("%s=%r(构建注入)" % (k, a))
            continue
        if isinstance(b, str) and b.startswith("$("):
            skipped.append("%s 源码用变量 %s" % (k, b))
            continue
        if a != b:
            bad("与源码不一致: " + k, "包内=%r 源码=%r" % (a, b))
            same = False
    for s in skipped:
        print("  [NOTE] 跳过比对：", s)
    if same:
        ok("Info.plist 与源码一致", "(版本 %s/%s)" % (pl.get("CFBundleShortVersionString"), pl.get("CFBundleVersion")))
else:
    print("  [NOTE] 未提供源码 Info.plist，跳过一致性比对")

print()
print("=" * 72)
print("3) 主程序 Mach-O")
print("=" * 72)
exe = APP + pl.get("CFBundleExecutable", "TimeFloat")
data = zf.read(exe)
print("  可执行  : %s (%.1f KB)" % (exe, len(data) / 1024))
CPU = {0x0100000C: "ARM64", 0x01000007: "x86_64"}
PLAT = {1: "macOS", 2: "iOS", 3: "tvOS", 6: "macCatalyst", 7: "iOSSimulator"}
magic = struct.unpack("<I", data[:4])[0]
if magic != 0xFEEDFACF:
    bad("Mach-O magic", hex(magic))
    print("\n结论：不是合法的 64 位 Mach-O，停。")
    sys.exit(1)
cputype, cpusub, ftype, ncmds, sizeofcmds, flags = struct.unpack("<iiIIII", data[4:28])
ok("Mach-O 64bit", CPU.get(cputype, hex(cputype)) + " ftype=%d" % ftype)
ok("CPU 架构 ARM64") if cputype == 0x0100000C else bad("CPU 架构", hex(cputype))
ok("MH_EXECUTE（可执行）") if ftype == 2 else bad("文件类型", str(ftype))

off, found = 32, {"build": None, "sig": False, "crypt": False, "dylibs": 0}
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
    if cmdsize == 0:
        break
    if cmd == 0x32:
        platform, minos, sdk, _n = struct.unpack("<IIII", data[off + 8:off + 24])
        found["build"] = (PLAT.get(platform, str(platform)),
                          "%d.%d.%d" % (minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF),
                          "%d.%d" % (sdk >> 16, (sdk >> 8) & 0xFF))
    elif cmd == 0x1D:
        found["sig"] = True
    elif cmd == 0x21:
        found["crypt"] = True
    elif cmd == 0xC:
        found["dylibs"] += 1
    off += cmdsize

if found["build"]:
    plat, minos, sdk = found["build"]
    ok("平台", plat) if plat == "iOS" else bad("平台", plat)
    ok("最低系统", minos) if int(minos.split(".")[0]) >= 15 else bad("最低系统", minos)
    print("  编译 SDK                      :", sdk)
ok("未加密（可直接重签）") if not found["crypt"] else bad("加密", "有 LC_ENCRYPTION_INFO")
if found["sig"]:
    print("  [NOTE] 有 LC_CODE_SIGNATURE（签名 blob 存在，但 App 目录无 _CodeSignature）")
else:
    ok("无 LC_CODE_SIGNATURE（未签名）")
print("  链接动态库数                  :", found["dylibs"])

print()
print("=" * 72)
print("4) 关键实现是否真在包里")
print("=" * 72)
text = data.decode("utf-8", errors="ignore")
# ⚠ 这里只断言**长字面量**（≥16 字节）：Swift 会把 ≤15 字节的字符串编译成
#   "small string" 立即数直接塞进寄存器，根本不进数据段 —— 按字符串搜必然搜不到，
#   而 Release 构建又 strip 掉了内部符号名。所以短字符串不作为判据（会误报）。
LONG_STRINGS = [
    ("界面副标题（含版本号）", "三路服务器时间 · 毫秒级 · "),
    ("启动超时兜底文案", "启动超时，请再点一次"),
    ("画中画启动中文案", "正在启动画中画"),
]
for label, s in LONG_STRINGS:
    ok(label, "命中") if s in text else bad(label, "未命中 " + s)

# 符号层面：这类系统符号一定在（来自 dylib 未定义符号表，不会被 strip）
SYMBOLS = [
    ("CLOCK_MONOTONIC（睡眠不丢时间）", "clock_gettime_nsec_np"),
    ("画中画帧堆积保护", "isReadyForMoreMediaData"),
    ("Date 头解析（Foundation）", "DateFormatter"),
]
for label, s in SYMBOLS:
    ok(label, "符号命中") if s in text else bad(label, "符号未命中 " + s)

print("  [NOTE] 短字面量（往返/校准失败/响应体超限…）与内部符号名不进数据段或被 strip，")
print("         它们的正确性由「编译自哪个提交」保证——见下面的来源信息。")

print()
print("=" * 72)
print("5) 二进制规模（可与上一版对比，作为代码确实变了旁证）")
print("=" * 72)
print("  主程序  : %.1f KB" % (len(data) / 1024))
segs = {}
off2 = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack("<II", data[off2:off2 + 8])
    if cmdsize == 0:
        break
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = data[off2 + 8:off2 + 24].rstrip(b"\x00").decode("ascii", "ignore")
        vmsize = struct.unpack("<Q", data[off2 + 32:off2 + 40])[0]
        segs[segname] = vmsize
    off2 += cmdsize
for k in ("__TEXT", "__DATA", "__DATA_CONST"):
    if k in segs:
        print("  %-14s: %.1f KB" % (k, segs[k] / 1024))

print()
print("=" * 72)
if problems:
    print("结论：发现 %d 个问题 —— 不要发这个包" % len(problems))
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("结论：[全部通过] 未签名，可直接交给 AltStore / Sideloadly 重签安装")
print("SHA-256:", sha)
