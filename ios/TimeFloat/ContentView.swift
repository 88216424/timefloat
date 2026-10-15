import SwiftUI

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
            .background(Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea())

            FloatingClockOverlay(hub: hub)
        }
        .onAppear { hub.start() }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("三源对时")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Text("三路服务器时间 · 毫秒级 · 抢购对时")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
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
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 40, alignment: .leading)
                        Text(line.time)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(line.time.hasPrefix("--") ? .white.opacity(0.4) : .white)
                        Spacer()
                        Text(line.deltaText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
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
                .foregroundStyle(.white.opacity(0.5))

            Divider().background(Color.white.opacity(0.12))

            Text(hub.detailText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
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
                .stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }

    // MARK: - 悬浮窗控制

    private var floatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("悬浮窗")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("显示：" + hub.selected.label)
                    .font(.system(size: 11))
                    .foregroundStyle(hub.selected.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }

            Text(pip.status)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))

            Button(pip.isActive ? "收起画中画悬浮窗" : "启动画中画悬浮窗") {
                if pip.isActive { pip.stop() } else { pip.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            HStack(spacing: 10) {
                Button("立即校时") { hub.refreshAll() }
                    .buttonStyle(.bordered)
                Spacer()
                Text("预览")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                PipPreviewView(renderer: pip)
                    .frame(width: 132, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Toggle("应用内悬浮卡片（仅本 App 前台可见，可拖动）", isOn: $inAppFloating)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .background(card)
    }

    // MARK: - 时间源

    private var card: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
