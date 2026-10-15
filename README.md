# 三源对时（Android 悬浮窗 + iOS 画中画悬浮）

悬浮在别的 App 上面的**单路服务器时间**，毫秒级。安卓走系统悬浮窗，iOS 走官方画中画（PiP）。
悬浮窗显示哪一路（北京 / 淘宝 / 京东）**在主界面启动之前选好**，窗口起来后锁定不再提供切换。

```
dist\
    三源对时-v1.0.apk      ← Android 已编译好，0.67MB，debug 签名，直接装
    （iOS 的 .ipa 不在这里：苹果的 iOS 二进制只能在 macOS + Xcode 上编译，
      本工程提供一键脚本和云编译两条路，见第六节）
android\                    ← Android 完整工程（Kotlin，零第三方依赖）
ios\                        ← iOS 完整工程（Swift，单 target，带 PiP 渲染器）
tools\check_sources.ps1     ← Windows 实测三个时间源
tools\diag_jd_source.ps1    ← 京东时间源专项诊断（README 里贴了实测输出）
tools\check_sources.sh      ← macOS 版
tools\build-ipa.sh          ← macOS 上一条命令打 .ipa
.github\workflows\ios-ipa.yml ← 没有 Mac？推到 GitHub 让云 runner 帮你打 .ipa
```

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
adb install -r dist\三源对时-v1.0.apk      # 覆盖安装不用卸载
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
# 输出：dist/TimeFloat-unsigned.ipa

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
bash tools/build-ipa.sh                                    # → dist/TimeFloat-unsigned.ipa
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

## 九、已知限制

| 项 | 说明 |
|---|---|
| iOS 无真·悬浮窗 | 系统不给第三方 App 这个权限，画中画是官方唯一合法路径；窗口尺寸位置由系统管且不接收触摸 |
| 京东精度上限 | Date 头本身只有秒精度，靠交集夹逼到 ±30ms；想更紧就多跑几轮（交集跨轮累积） |
| 厂商省电策略 | 小米/华为/OPPO 需把本 App 加进"后台运行白名单"，否则前台服务可能被杀（不用 Root） |
| 悬浮窗只显示一路 | 按你的要求做的（三选一），要看三路回主界面 |
