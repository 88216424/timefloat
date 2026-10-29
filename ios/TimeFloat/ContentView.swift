import SwiftUI

/// 统一调色板 —— 与 Android 端 `res/values/colors.xml` 一一对应。
/// 以前颜色散落在各个 View 里（同一种"次级文字"出现好几个不同白度），
/// 界面看着发灰发脏；现在收敛成三级文字 + 一组语义色。
enum Palette {
    static let bgTop = Color(red: 0.06, green: 0.07, blue: 0.11)
    static let bgBottom = Color(red: 0.02, green: 0.02, blue: 0.04)

    static let accent = Color(red: 1.00, green: 0.42, blue: 0.00)   // #FF6A00
    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.10)
    static let chipFill = Color.white.opacity(0.10)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.70)            // ≈ #B3
    static let textTertiary = Color.white.opacity(0.50)             // ≈ #80

    static let ok = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warn = Color(red: 1.00, green: 0.76, blue: 0.03)
    static let danger = Color(red: 1.00, green: 0.55, blue: 0.52)
}

struct ContentView: View {
    @EnvironmentObject private var hub: ClockHub
    @StateObject private var pip = PipClockRenderer(clock: { ClockHub.shared.selected })
    @AppStorage("inAppFloating") private var inAppFloating = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    heroCard
                    floatCard
                }
                .padding(16)
            }
            // 只留一层：SwiftUI 里 .background 叠加时后加的在更底层，
            // 之前写了"纯色 + 渐变"两层，纯色会把渐变整个盖住（等于白写）
            .background(
                LinearGradient(colors: [Palette.bgTop, Palette.bgBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )

            FloatingClockOverlay(hub: hub)
        }
        .onAppear {
            hub.start()
            // 进前台就把渲染层准备好：否则那个 132×48 的预览框在点「启动画中画」之前是全黑的
            pip.preparePreview()
        }
    }

    // MARK: - 顶部

    /// 版本号：跟 Android 端底部脚注对齐，让"设备上装的是哪一版"一眼可见
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("三源对时")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("三路服务器时间 · 毫秒级 · \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    // MARK: - 主卡：三路时间（点选一路给悬浮窗用）

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hub.localSkewText)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(hub.localSkewTint)
            Text(hub.crossText)
                .font(.system(size: 12))
                .foregroundStyle(hub.crossTint)

            ForEach(hub.lines) { line in
                Button {
                    if pip.isActive { return }
                    hub.select(line.id)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(line.color).frame(width: 8, height: 8)
                        Text(line.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 40, alignment: .leading)
                        Text(line.time)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(line.time.hasPrefix("--")
                                             ? Palette.textTertiary
                                             : Palette.textPrimary)
                        Spacer(minLength: 6)
                        // 固定最小宽度，让三个 chip 的右边缘对齐
                        Text(line.deltaText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(minWidth: 40)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.chipFill))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(hub.selectedId == line.id
                                  ? line.color.opacity(0.18)
                                  : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(hub.selectedId == line.id
                                        ? line.color.opacity(0.6) : Color.clear,
                                        lineWidth: 1.2))
                    )
                }
                .buttonStyle(.plain)
            }

            Text(pip.isActive
                 ? "画中画运行中，显示源已锁定"
                 : "点一下要盯的那路时间，启动悬浮窗后就显示它")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)

            Rectangle()
                .fill(Palette.divider)
                .frame(height: 1)

            // 每路一行：名称 + 往返时间 + 多久前校准
            Text(hub.detailText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(heroBackground)
    }

    private var heroBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.15, blue: 0.20),
                                          Color(red: 0.06, green: 0.07, blue: 0.10)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(Palette.accent.opacity(0.28), lineWidth: 1))
    }

    // MARK: - 悬浮窗控制

    private var floatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("悬浮窗")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("显示：" + hub.selected.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hub.selected.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.chipFill))
            }

            Text(pip.status)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)

            Button(pip.isActive ? "收起画中画悬浮窗" : "启动画中画悬浮窗") {
                if pip.isActive { pip.stop() } else { pip.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)

            HStack(spacing: 10) {
                Button("立即校时") { hub.refreshAll() }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)

                Spacer()

                Text("预览")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                PipLayerHost(renderer: pip)
                    .frame(width: 132, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.cardStroke, lineWidth: 1))
            }

            Rectangle()
                .fill(Palette.divider)
                .frame(height: 1)

            Toggle("应用内悬浮卡片（仅本 App 前台可见，可拖动）", isOn: $inAppFloating)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .tint(Palette.accent)
        }
        .padding(16)
        .background(card)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Palette.cardFill)
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Palette.cardStroke, lineWidth: 1))
    }
}
