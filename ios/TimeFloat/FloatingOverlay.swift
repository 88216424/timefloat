import SwiftUI

/// 应用内悬浮卡片（只显示选中的那一路，可拖动）
struct FloatingClockOverlay: View {
    @ObservedObject var hub: ClockHub
    @AppStorage("inAppFloating") private var enabled = false
    @AppStorage("floatX") private var savedX = 20.0
    @AppStorage("floatY") private var savedY = 180.0
    @State private var drag = CGSize.zero

    var body: some View {
        GeometryReader { geo in
            if enabled {
                let clock = hub.selected
                // 夹取范围要防"反过来"：窄屏/分屏时 geo.width - 90 可能小于 90，
                // 原来的 min(max(x, 90), width-90) 会算成负数 → 卡片被推出屏幕
                let halfW: CGFloat = 90
                let halfH: CGFloat = 60
                let xMax = max(halfW, geo.size.width - halfW)
                let yMax = max(halfH, geo.size.height - halfH)
                let curX = min(max(savedX + drag.width, halfW), xMax)
                let curY = min(max(savedY + drag.height, halfH), yMax)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(clock.statusColor).frame(width: 7, height: 7)
                        Text(clock.label + "服务器时间")
                            .font(.system(size: 11))
                            .foregroundStyle(clock.accentColor)
                    }
                    // 只显示服务器名 + 时间，别的都不放
                    Text(clock.utcMsOrNil().map { Fmt.hms($0) } ?? "--:--:--.---")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(clock.utcMsOrNil() == nil ? Palette.warn : Palette.textPrimary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.86))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Palette.cardStroke, lineWidth: 1))
                )
                .position(x: curX, y: curY)
                .gesture(
                    DragGesture()
                        .onChanged { v in drag = v.translation }
                        .onEnded { _ in
                            savedX = min(max(savedX + drag.width, halfW), xMax)
                            savedY = min(max(savedY + drag.height, halfH), yMax)
                            drag = .zero
                        }
                )
            }
        }
        .allowsHitTesting(enabled)
    }
}
