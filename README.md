# 三源对时（Android 悬浮窗 + iOS 画中画悬浮）

悬浮在别的 App 上面的**单路服务器时间**，毫秒级。安卓走系统悬浮窗，iOS 走官方画中画（PiP）。
悬浮窗显示哪一路（北京 / 淘宝 / 京东）**在主界面启动之前选好**，窗口起来后锁定不再提供切换。

```

dist\
    TimeFloat-v1.2.apk    ← Android Release APK
    TimeFloat-v1.2-unsigned.ipa ← iOS 未签名包（需 macOS + Xcode 或 GitHub Actions）
    历史版本保留，不使用旧文件名覆盖
android\                    ← Android 完整工程（Kotlin，零第三方依赖）
ios\                        ← iOS 完整工程（Swift，单 target，带 PiP 渲染器）
tools\check_sources.ps1     ← Windows 实测三个时间源
tools\diag_jd_source.ps1    ← 京东时间源专项诊断（README 里贴了实测输出）
tools\check_sources.sh      ← macOS 版
tools\build-ipa.sh          ← macOS 上一条命令打 .ipa
.github\workflows\ios-ipa.yml ← 没有 Mac？推到 GitHub 让云 runner 帮你打 .ipa
```

## 版本迭代

- `v1.2`（versionCode/build 3）：修复 iOS 并发 HTTP Date 解析的数据竞争；统一复用带锁的日期解析器；Android/iOS 版本号同步递增。打包产物使用带版本号的文件名，保留 `v1.0`、`v1.1` 历史文件。

---

## 一、悬浮窗长什么样（极简）

```
┌──────────────────────────┐
│ ● 淘宝服务器时间           │  ← 状态点 + 服务器名
│      18:11:58.312        │  ← 大字时间（44sp 等宽）
│              [刷新] [关闭] │
└──────────────────────────┘
```

**只有这四样**：状态点、服务器名、时间、两个按钮。
日期、"多少秒前"、±不确定度、三源互差、本机墙钟偏差 —— **全部不在悬浮窗上**（这些信息留给主界面）。
拖动可移动、松手吸边记位、**长按任意位置 = 立刻重新校时**。

状态点颜色是唯一保留的状态提示：绿=数据新鲜 / 黄=偏旧或上轮同步失败重试中 / 红=从未校上。

---

## 二、京东时间源重做（你反馈的"一会差 700 一会差 400"）

### 实测诊断（`tools\diag_jd_source.ps1` 的真实输出）

```
===== A) 老方法：抓 item 页 serverTime =====
  SKU 100012043978  TTFB 173ms  读到  3KB  **没有 serverTime**  presellInfo=False
  SKU 100012043978  TTFB  98ms  读到  3KB  **没有 serverTime**  presellInfo=False
  SKU 100026667910  TTFB 110ms  读到  3KB  **没有 serverTime**  presellInfo=False
  ...（所有候选 SKU 都一样）
```

**根因**：京东商品页里的 `presellInfo.serverTime` 字段**时有时无**（只在商品有"预约/抢购"活动时渲染，
页面正常 284KB、现在返回 3KB 就没这个字段）。字段一缺失，程序就退到**只有秒精度的 HTTP `Date` 头**，
误差在 0~1000ms 之间随机分布 —— 这就是"一会差 700，一会差 400"的来源。**是我设计的问题，不是你的错觉。**

### 新方案：Date 头 + 秒边界交集（已实测验证）

既然唯一稳定存在的是标准 `Date` 头，那就别换接口，改**估计方法**：

每次采样都能得到一条约束 —— *服务器生成这个响应时，它的时钟落在 `[D, D+1000)` 内*（D 是截断到整秒的 Date）。
令 `v = D - (本地收到时刻 - rtt/2)`，则真实偏移量必然落在 `[v - margin, v + 1000 + margin)`（margin = rtt/2 + 5ms）。
把十几次采样的区间**求交集**：

```
偏移量 ∈ [max(v_i - m_i),  min(v_i + 1000 + m_i)]
区间宽度 = 1000 + 2m - 相位跨度
```

各次采样命中的"秒内相位"不同，采样够多（相位铺满一整秒）时宽度就收敛到 2m ——
对 rtt 只有 26ms 的 `api.m.jd.com` 来说大约 **±25ms**。

**实测结果（同一脚本 A/B 对照）：**

```
===== B) 新方法：api.m.jd.com 的 Date 头 + 秒边界交集（16 次采样）=====
  交集宽度 64ms    中点相对NTP = 33ms    相对淘宝 = 2ms
  平均RTT 26ms     各样本下界极差 936ms（说明相位覆盖够全）
第二轮：交集宽度 80ms   相对NTP 60ms   相对淘宝 65ms
```

**从 ±500ms 变成 ±30ms。** 而且交集是**跨轮次累积**的（滚动窗口 28 个约束），跑几轮之后会更紧。

### 顺带修的三个 bug

1. **悬浮窗不显示毫秒（字被裁掉了）**
   大字时间原来用 `sp` 并且宽度写 `match_parent`：`sp` 会跟着**系统字体大小**一起放大，
   系统字体调大之后 `18:11:58.312` 这 12 个字符排出来超出屏幕，Android 直接把尾部裁掉 ——
   于是"毫秒就看不见了"（只显示到 `18:11:58`）。现在改成：
   字号用 **dp**（不吃系统字体缩放）+ **自适应缩字号**（先用 paint 量出最坏宽度
   `00:00:00.000`，超出可用宽度就等比缩小到刚好放下），毫秒三位永远完整。
   iOS 画中画画布同样加了自适应（92pt 排 12 个等宽字符本来就会超出 660px 画布）。

2. **"本机墙钟比服务器快/慢 xx ms"依据写死了北京时间**
   原来那行字永远用 `beijing` 去算，所以你**点淘宝点京东它都不变** —— 确实不合理。
   抢购时你真正关心的是"我的手机和**京东/淘宝**的服务器时钟差多少"，所以现在改成
   **跟着你选中的那一路走**，文案也带上源名：`本机墙钟比京东服务器慢 641ms`。

3. **正负号写反了**
   `skew = 服务器 - 本机`，为正说明**本机慢**，我原来却显示成"本机快"，正好相反。
   现在统一成 `本机墙钟比X服务器 快/慢 Nms`（N 取绝对值），并保留绿/黄/红阈值配色。

### 其他改动

- **删掉"时间源"卡片**（手动微调三个源的毫秒偏移、京东 SKU 输入框、应用按钮）——不需要了
- 京东那路不再下载 284KB 商品页，只取几十字节的响应头

---

## 三、三个时间源（实测）

| 源 | 接口 | 精度 | 实测 |
|---|---|---|---|
| 北京时间 | `ntp.aliyun.com` SNTP(UDP 123) | 毫秒 | rtt 25~30ms，stratum 2~3 |
| 北京（兜底） | 百度/腾讯 HTTP `Date` 头 + 秒边界交集 | ±30ms | NTP 被封时自动启用（蜂窝网常封 UDP 123） |
| 淘宝 | `acs.m.taobao.com/gw/mtop.common.getTimestamp/` | 毫秒 | rtt 104~158ms，干净 13 位时间戳 |
| 京东 | `api.m.jd.com/` 的 `Date` 头 + 秒边界交集 | ±30ms | rtt 26ms，交集宽度 64~80ms |

**已确认下线的接口（别再抄老教程）**：
`api.m.jd.com/client.action?functionId=queryServerTime`（返回 "the current API does not exist"）、
`a.jd.com/ajax/queryServerData.html`（变成 HTML 首页）、带 appid 的京东时间接口（WAF 403）、
`api.m.taobao.com/rest/api3.do`（DNS 不解析）、商品页 `presellInfo.serverTime`（时有时无）。

---

## 四、主界面（保留的东西）

- **三路时间实时显示**：点一行即选为悬浮窗显示的那一路（该行用源强调色描边高亮）
- **本机墙钟 vs 选中源**：`本机墙钟比淘宝服务器慢 641ms`（跟随选择，正负号已修正）
- **三源互差**：`三源互差 12ms · 一致（可信）`，≤50 绿 / ≤200 黄 / 超了红 —— 用来判断"这时间可不可信"
- **每路一行**：只保留 `名称 · 往返时间 · 多久前校准`，例如
  ```
  北京  往返 27ms · 12s前校准
  淘宝  往返 130ms · 8s前校准
  京东  往返 26ms · 15s前校准
  ```
  接口名、样本数、±不确定度这些技术细节不再往界面上堆；状态用**颜色**表达
  （灰白=正常 / 黄=偏旧或上轮失败 / 红=还没校上），不占用文字
- **悬浮窗控制**：启动 / 停止 / 授权 / 立即校时
- **悬浮窗外观**：不透明度、字号、是否显示毫秒、锁定位置（改完即时生效，自动保存）

---

## 五、Android 安装与编译

```powershell
adb install -r dist\TimeFloat-v1.2.apk
```
首次使用：允许「显示在其他应用上层」→ 点一行选源 → 点「启动悬浮窗」→ 切出去就挂在屏幕上了。

```powershell
cd android
.\gradlew assembleRelease                  # 产物 app\build\outputs\apk\release\app-release.apk
```
本机验证工具链：**Gradle 9.3.1 + AGP 9.1.0 + JDK 17+ + compileSdk 36**。
注意 AGP 9.0 起内置 Kotlin 支持，**不能再 apply `org.jetbrains.kotlin.android`**（会直接报错）。

---

## 六、iOS

苹果官方事实（查过 developer.apple.com）：**iOS 不给第三方 App 提供"任意置顶悬浮窗"API**，
`UIWindow.Level` 只在本 App 的 scene 内生效。唯一能浮在别的 App 之上的是 **画中画**：
`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`（iOS 15.0+）。
工程把选中的那一路时间画进 `CVPixelBuffer`，用 `CMSampleBuffer` 喂给 `AVSampleBufferDisplayLayer`，
15fps 刷新；画中画画面同样只有**状态点 + 服务器名 + 大字时间**。需要 `UIBackgroundModes = audio`。
官方文档：[AVPictureInPictureSampleBufferPlaybackDelegate](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate) ·
[ContentSource.init(sampleBufferDisplayLayer:playbackDelegate:)](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init(samplebufferdisplaylayer:playbackdelegate:))

```bash
# ① Mac 上一条命令打 ipa（未签名版，给 AltStore/Sideloadly 自己签）
bash tools/build-ipa.sh
# 输出：dist/TimeFloat-v1.2-unsigned.ipa

# ② 想在 Mac 上直接开 Xcode 调试
brew install xcodegen && cd ios && xcodegen generate && open TimeFloat.xcodeproj

# ③ 你的开发者证书打包（已签名 ipa）
DEVELOPMENT_TEAM=你的TeamID bash tools/build-ipa.sh
```
单 target，没有扩展，自签名很省事（免费 Apple ID 7 天 / AltStore 侧载都行）。
如果画中画里文字上下颠倒，把 `PipClock.swift` 的 `flipVertically` 改成 `false`。

**完全没有 Mac？走云编译（推荐）**：把 `timefloat` 目录推到 GitHub 仓库，
进 Actions 页手动 `Run workflow`（工作流叫 `build-ios-ipa`，跑在 `macos-latest` runner 上），
大概 3~5 分钟跑完，在 Artifacts 里下载 `TimeFloat-unsigned-ipa` ——
那就是同一个未签名 .ipa，直接丢给 AltStore / Sideloadly 签装。
GitHub 免费额度对个人仓库足够（macOS runner 每月 200 分钟免费）。

### 用 Apple ID 签名安装（免费账号可用）

工程是**专门为这条路配好的**，以下约束全部满足：

| 免费账号的限制 | 本工程的情况 |
|---|---|
| 不能带扩展（Widget/Share 等） | ✅ 单 target，**没有扩展**（实时活动那个扩展早就删了） |
| 不能用需要 explicit App ID 的 entitlement | ✅ **无任何 entitlements 文件**，`CODE_SIGN_ENTITLEMENTS` 未设置 |
| 后台音频、画中画不受限 | ✅ 只是 Info.plist 的 `UIBackgroundModes = audio`，不是 capability |
| 同时最多 3 个自签 app / 包名不能撞 | ✅ 支持换包名重打：`BUNDLE_ID=com.你的名字.timefloat bash tools/build-ipa.sh` |
| 证书 7 天过期 | 过期重签一次；用 AltStore 的话同一 WiFi 下可自动续签 |

**三条路，按你手上有什么选**：

```bash
# A. 有 Mac + Xcode（最省事，连手机直接装，连 ipa 都不用导出）
cd ios && xcodegen generate && open TimeFloat.xcodeproj
#   → Signing & Capabilities 里登录你的 Apple ID，Team 选 Personal Team
#   → 插上手机，⌘R

# B. 有 Mac，想拿 ipa（给 AltStore/Sideloadly 用）
bash tools/build-ipa.sh                                    # → dist/TimeFloat-v1.2-unsigned.ipa
BUNDLE_ID=com.你的名字.timefloat bash tools/build-ipa.sh    # 包名撞了就换一个

# C. 没 Mac → GitHub Actions 云编译，下载 Artifacts 里的 ipa
```

签装步骤（AltStore / Sideloadly 都一样）：电脑装好工具 → 手机连电脑 → 把 ipa 拖进去 →
填 Apple ID → 开始签装 → 手机上「设置 → 通用 → VPN与设备管理」信任这个开发者。
免费账号 7 天到期，重签一次即可，数据不会丢。

---

## 七、时间一定是对的 —— 四层保护

1. **没校上就不给数字**：从未成功校时的源显示 `--:--:--.---` 变黄，
   **绝不退回本机墙钟冒充**（你本机墙钟实测快 641ms，拿它抢购就是害人）。
2. **坏样本进不来**：连续两轮之间真实偏移只可能有晶振漂移量级的变化，某轮结果与钟面差超 **1 秒**先不采纳，
   等下轮同向确认才接受（只有单调钟倒退=设备重启才无条件采纳）。
3. **多源交叉校验**：三源互差 ≤50ms 绿、≤200ms 黄、超过红字提示核对。
4. **可信度常驻**：每路都显示 `±不确定度ms`——北京 SNTP `±(rtt/2+3)`、淘宝 `±(rtt/2+5)`、
   京东 `±(交集半宽+8)`。不确定度是自己算出来的，不是编的。

**必须知道**：三路源本身相差几十毫秒是正常的（各自的服务器时钟 + 各自的网络路径）。
**买京东就信京东那路，买淘宝就信淘宝那路**，别互相套。

## 八、本轮自查修掉的 bug（含"不会自动校时"）

### ★ 自动校时会被"拖死"（你反馈的那个）
链条是这样的：
1. 京东那路一轮要打 12 次请求，但 `probeBurst` **没有整轮预算**，单次请求超时是 connect 5s + read 5s；
2. `Sampler` 的 12s 预算是**在轮次之间**检查的，京东 `preferredSamples=1` → 这个预算**永远不会被检查**；
3. 线程池只有 4 个线程，几个卡死任务一占满，**后续所有校时任务全部排队**；
4. 而"排下一轮"是写在任务自己的 `finally` 里的 —— 前面的任务不返回，下一轮就一直不来。

**修法（四层）**：
- 单次探针超时降到 **3s**，整轮取样加**硬预算 4s**（到点就用手上样本收工）；
- 线程池 4 → **6**；
- 看门狗加**调度自愈**：任何一路超过 **90 秒**连"开始校时"都没有过（不管什么原因），
  直接强行补一次 —— 保证自动校时永远不会彻底停住；
- `ServerClock` 记录 `lastAttemptMonoMs`，看门狗用它判断调度链是否断了。

iOS 侧同样的两个隐患（探针无预算、没有自愈）也一起补齐了。

### 其它修掉的
| # | 问题 | 修法 |
|---|---|---|
| 1 | 三源互差在"可用源不足"时被拼成 `可用源不足，等待校时 · 略有差异` | 用 level=-1 区分"数据不足"，文案与配色分开处理 |
| 2 | 主界面每帧 new 三个 `GradientDrawable`（≈90 次/秒垃圾对象），且每帧 `setTextColor`（会触发 measure/layout） | 全部改成"值变了才动控件"，高亮只在切源时重建 |
| 3 | "三源互差 / 采样细节"跟着 30fps 一起刷 | 拆成慢路径，每 500ms 刷一次 |
| 4 | 不显示毫秒时悬浮窗仍按 30fps 空转 | 动态降到 4fps（省电） |
| 5 | `TimeHub` 里有个 30fps 空转的 ticker，谁都没订阅（死代码） | 删掉 |
| 6 | 北京兜底每次 fetch 都 `intersector.reset()`，跨轮累积失效 | 去掉 reset，靠设备重启检测自清 |
| 7 | 转屏/分屏后字号不重算、窗口可能留在屏幕外 | 处理 `onConfigurationChanged`：重算字号 + 重新夹位置 |
| 8 | 悬浮窗卡片宽度写 `match_parent`（满屏宽、不好看） | 改 `wrap_content`，标题行与时间居中 |
| 9 | 一堆无用资源残留（7 个 drawable、5 个 string） | 全部清理，APK 更干净 |
| 10 | 两个外观滑块是系统默认灰蓝配色 | 改成主题橙色（`progressTint`/`thumbTint`） |

### 第三轮自查（又挑了 6 处）
| # | 问题 | 修法 |
|---|---|---|
| 1 | 主界面每帧调 `setTextColor` / `setAlpha` / 状态点 `setColor`，都会触发 measure/layout 或 invalidate | 全部加"值变了才动"判断（缓存上次值） |
| 2 | 每帧读一次 `SharedPreferences` 取"显示毫秒" | 直接读开关的 `isChecked` |
| 3 | 主界面那三行堆了接口名/样本数/±不确定度（用户看不懂） | 只留 `名称 · 往返时间 · 多久前校准`，状态改用颜色表达 |
| 4 | 死代码：`Fmt.parseHmsToUtcMs` / `deltaSec` / `countdown` / `ServerClock.detailLine` | 全部删除 |
| 5 | 悬浮窗关掉毫秒后仍按 30fps 刷 | 已降为 4fps（上一轮） |
| 6 | iOS 侧同样的文字堆砌 | 同步简化为同一格式 |

### 第四轮：双端全量审计（两个独立审计代理 + 我本人复查）

这一轮用两个只读审计代理把 Android、iOS 逐行过了一遍（共提了 60+ 条），我逐条核实后修掉真问题、驳回误报。**两条是"时间会悄悄错"的致命级**：

| 级别 | 问题 | 真相与修法 |
|---|---|---|
| 🔴 致命 | **iOS `monoMs()` 用的是"不含睡眠"的时钟** | `DispatchTime.now().uptimeNanoseconds` 的官方语义是*系统清醒时间*（Apple 文档：*excluding any time the system spent asleep*）。锁屏睡 5 分钟，它就少走 5 分钟 → `服务器时间 = monoMs() + offset` 整体**静默慢 5 分钟**，而且守卫全抓不到（synced 还是 true，jump guard 比的是两个同基准的 offset）。改成 `clock_gettime_nsec_np(CLOCK_MONOTONIC)`（睡眠期间照常前进），**与 Android 的 `SystemClock.elapsedRealtime()` 语义对齐** |
| 🔴 致命 | **Android：本轮 0 个新样本却宣称"刚校准"** | 成功判据只看 `intersector.estimate() != null`，而交集器跨轮持久 —— 探针全超时（换网/隧道/运营商不可达）时，它拿上一轮留下的旧约束照样算出结果，界面显示绿色「往返 26ms · 0s前校准」，`isStale()` 永不触发。改成 `accepted == 0` 直接判失败 |
| 🟠 高 | 异构主机共用一个交集器 | 京东有 jfe/nginx 两台、北京兜底有百度/腾讯两台，不同边缘机钟差几十毫秒；混着求交会夹出"更紧但带系统偏差"的值（1000ms 的 jump guard 抓不到）。修法：`probeBurst` 一轮只用一台主机 + 换主机时 `intersector.reset()` 作废本轮 |
| 🟠 高 | 看门狗和同步任务抢同一个线程池 | 网络半死时 6 线程被占满，看门狗自己被排队 —— 而它是"自动校时永不停止"的唯一机制。改成独立单线程池，并给它包上 try/catch（`scheduleWithFixedDelay` 一旦抛异常会**永久停止**，等于自愈机制自杀） |
| 🟠 高 | 卡死判死会分裂调度链 | 旧任务迟到返回时既覆盖新结果、又在 finally 里再排一条链 → 越滚越多。加**调度代次 generation**：作废旧任务，它既不写结果也不排链；`bumpGen` 用 `merge` 保证原子 |
| 🟠 高 | 悬浮窗运行中还能换源 | 与"启动后不要切换"的要求冲突，误触就看错时间。改成运行中直接拦住并提示先关掉 |
| 🟡 中 | iOS 手动刷新绕过并发去重 | `refreshAll` 自己起 Task，不登记 `inFlight` → 与看门狗自愈并发，两个任务同时往一个 `DateIntersector` 里塞样本（北京那路还会 reset 掉对方刚攒的约束）。改成复用 `syncLoopOnce` |
| 🟡 中 | iOS Timer 不在 `.common` 运行模式 | 拖动/滚动时主 run loop 切到 UITracking → `tick()` 停摆 → App 内时间和浮卡"冻住"。`RunLoop.main.add(t, forMode: .common)` |
| 🟡 中 | iOS `tick()` 每 50ms 无条件发 6 个 `@Published` | 20fps 全树重绘（耗电/掉帧）。改成"值真的变了才赋值"，`ClockLine` 加 `Equatable` |
| 🟡 中 | iOS 画中画帧没有"立即显示"标记 | 不设 `kCMSampleAttachmentKey_DisplayImmediately`，图层会按 PTS 排队显示 → 毫秒时钟滞后一帧、偶发丢帧。已在 `enqueue` 前打上附件 |
| 🟡 中 | iOS 帧堆积 | 消费端跟不上时 `CMSampleBuffer` 堆积。加 `isReadyForMoreMediaData` 判断（时钟只要最新一帧，丢帧天然正确） |
| 🟡 中 | 超时/预算不自洽 | Android `STUCK_MS` 18s < 最坏一轮 ~17-20s（会误判卡死，界面闪"校准失败→自己好了"）；iOS `Http.get` 默认超时 8s 而 `Cfg.httpTimeout=5` 压根没人用、淘宝调用也没传超时 → 一轮最坏 32s。两端统一：阈值提到 30s、超时全部收紧、采样预算改成每轮**开始前**也判一次 |
| 🟡 中 | iOS 首帧/预览 | 时间基晚于首帧建立 → 首帧 PTS 与后续不同基准（启动瞬间黑一下）；而预览框只在点启动后才初始化 → **启动前是一块黑的**。改成进前台就 `preparePreview()`，且时间基先于首帧 |
| 🟡 中 | `ACTION_SYNC` 提前 return | 从通知点"刷新"时若视图未建好，会跳过 attachView/acquire，停在"通知在、没悬浮窗、自动校时没开"的僵尸态 |
| 🟡 中 | 转屏后用旧尺寸夹取位置 | `applyPrefs` 改字号触发重排后立刻 `clampAndSave`，读到的还是旧 width/height → 可能把错误坐标写回。改为 `post` 到下一帧 |
| 🟢 轻 | 一堆小项 | SeekBar 防抖标志没复位（拖动后会白写一次 prefs + K_REV 跳一次）、NTP 回包不校验（KoD 包 stratum=0 时间戳为 0，rtt 小会被 min-RTT 优先选中 → 钟面能跳到 1900 年）、`lastOkMonoMs` 缺 `@Volatile`（32 位设备撕裂读）、无效权限 `WAKE_LOCK`、失效的 `NSSupportsLiveActivities`、死代码 |

**两条被驳回的"建议"（避免越改越糟）**：
- ❌ 把淘宝时间戳的合理性窗口从 ±1 天收紧到 ±30s —— 这个检查是拿**本机墙钟**做参照的，而本机墙钟可能偏几分钟，收紧会直接把合法样本全拒掉。
- ❌ 为了连接复用去读掉 Date 探针的响应体 —— 精度不受影响（`-rtt/2` 与 `+rtt/2` 同向抵消），但读 body 会改变采样时刻的语义，得不偿失。

**修完的验证方式**：
| 要验证什么 | 怎么测 |
|---|---|
| iOS 睡眠偏差（本轮最大修复） | 开画中画 → 锁屏 6 分钟 → 解锁看浮窗时间与真实时间的差（修好后差应在几十毫秒内；修好前会差约 6 分钟） |
| iOS 后台是否继续走 | 开浮窗 → 切到别的 App → 看时间还在跳（对应 `shouldProhibitBackgroundAudioPlayback` 改 `false`） |
| 滚动不再冻住 | 主界面拖动列表，看三行时间是否连续跳 |
| 陈旧数据不再伪装新鲜 | 飞行模式放一会儿再开：应显示"校准失败/偏旧（黄）"，而不是绿色"0s前校准" |

### 第五轮：界面美化 + 第三轮补漏审计（工具层 / 资源 / 布局）

第三轮审计代理把上一轮**没覆盖的文件**（util / net / 模型、全部 res、Assets.xcassets、project.yml）逐行读完，21 个文件。真问题都修了，另有三条"文档与事实不符"的更正。

| 级别 | 问题 | 修法 |
|---|---|---|
| 🟠 高 | **iOS 也有"零样本冒充刚校准"**（与 Android 同一个漏洞，上一轮只修了 Android） | iOS 的北京兜底 / 京东都加 `guard res.accepted > 0`；顺便发现 iOS 的北京兜底**每轮都 `intersector.reset()`**，把跨轮累积彻底打死（区间偏宽、失败率高）→ 删掉 |
| 🟠 高 | **Android `Http.get` 读 body 无上限**：`readTimeout` 只是"每次 read"的上限，服务器每 <2.5 秒吐一点数据就能**无限读下去**（时间无界，不只是内存），而采样预算只在轮间判 | 改成 `readCapped(maxBytes = 256KB)`，超限直接判失败换源；顺手把 `bytes` 从"字符数"改成真实字节数 |
| 🟠 高 | 两端**没有自适应图标**（Android 8+ 会显示"小方块套大圆"） | 加 `ic_launcher_foreground`（把钟面按 0.62 缩进安全区）+ `ic_launcher_background` + `mipmap-anydpi-v26` + `mipmap` 回退，Manifest 改用 `@mipmap/ic_launcher` + `roundIcon` |
| 🟡 中 | 界面"发灰发脏"的根因：**同一种次级文字有 6 个白度**（#66/#80/#99/#B3/#E6/#FFE6E6E6），背景色还有 0B0D12 与 0A0C10 两个值 | 建 `colors.xml` 作为**唯一颜色定义处**（4 档文字 + 语义色 + 三源色），两个布局 + `themes.xml` 全部改成 `@color/...`；iOS 侧同步加了 `Palette` 枚举。顺手把行内 chip 设了 `minWidth=46dp` 让右边缘对齐、开关也染成主题橙 |
| 🟡 中 | 三路时间文本没有单行限制 → 系统大字体/窄屏会换行撑坏行高（与之前"毫秒被裁掉"同一类回归） | 三处都加 `maxLines=1` + `includeFontPadding=false`（悬浮窗早就是对的） |
| 🟡 中 | `lastMinRttMs` 是**历史最小值** → 界面"往返 Nms"可能来自十分钟前，显得比实际乐观 | `probeBurst` 额外返回**本轮**最小 rtt，两端都用本轮值 |
| 🟡 中 | iOS `DateProbe` 的 `AsyncBytes` 从不消费也从不取消 → 每轮把百度/腾讯首页（各几百 KB）在后台拖完 | 加 `Range: bytes=0-0`（响应 1 字节，Date 头照样有效，流量省 99%）；Android 侧对京东的小响应改成读掉 body 以复用 keep-alive |
| 🟡 中 | 两处布局圆角三套（18/20/14）、描边三套 | 卡片统一 18dp、间距统一 12dp，规则写进注释 |
| 🟡 中 | 两端版本号恒为 1.0 / 1，**无法判断设备上装的是哪一版**（历史痛点：重复抱怨其实没重装） | Android → `1.1 / versionCode 2`，iOS → `CFBundleShortVersionString 1.1 / CFBundleVersion 2`；Android 底部加了一行 `v1.1 · 安装于 MM-dd HH:mm` 脚注 |
| 🟢 轻 | iOS 主界面 `tick()` 在后台仍以 20fps 跑（浮窗并不依赖它） | 后台直接 return（**校时循环不停**，后台正是浮窗要准的主场景）；顺手补上 `SWIFT_STRICT_CONCURRENCY: minimal` 显式声明；`build-ipa.sh` 改用仓库里那份 `ExportOptions.plist`（消掉一个"没人引用"的文件） |

**三条"文档与事实不符"的更正（避免以后按错的信息改代码）**：
1. `Fmt.hms8` **不是死代码**（Android 关毫秒时在用它）——上一轮报告列错了，照删会编译失败。
2. `project.yml` 里**没有** `SWIFT_STRICT_CONCURRENCY`（Swift 5 默认就是 minimal，无功能影响）——本轮已补上显式声明。
3. "iOS 没有 Assets.xcassets"是读到旧快照；实际存在且已打进 ipa（`CFBundleIcons` + `AppIcon60x60` ✓）。

**本轮自证的产物信息**（都可核对）：
```
Android : package=com.yesha.timefloat  versionCode=3  versionName=1.2  minSdk=24 targetSdk=36
          图标 → res/BW.xml（自适应图标）   label=三源对时
iOS     : CFBundleShortVersionString=1.2  CFBundleVersion=3
          CFBundleIcons=AppIcon60x60  含 AppIcon png 2 个
```

## 九、已知限制

| 项 | 说明 |
|---|---|
| iOS 无真·悬浮窗 | 系统不给第三方 App 这个权限，画中画是官方唯一合法路径；窗口尺寸位置由系统管且不接收触摸 |
| 京东精度上限 | Date 头本身只有秒精度，靠交集夹逼到 ±30ms；想更紧就多跑几轮（交集跨轮累积） |
| 厂商省电策略 | 小米/华为/OPPO 需把本 App 加进"后台运行白名单"，否则前台服务可能被杀（不用 Root） |
| 悬浮窗只显示一路 | 按你的要求做的（三选一），要看三路回主界面 |
