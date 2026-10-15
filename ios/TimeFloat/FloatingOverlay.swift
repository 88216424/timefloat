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
                        .foregroundStyle(clock.utcMsOrNil() == nil ? .yellow : .white)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.88))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1))
                )
                .position(x: min(max(savedX + drag.width, 90), geo.size.width - 90),
                          y: min(max(savedY + drag.height, 60), geo.size.height - 60))
                .gesture(
                    DragGesture()
                        .onChanged { v in drag = v.translation }
                        .onEnded { _ in
                            savedX = min(max(savedX + drag.width, 90), geo.size.width - 90)
                            savedY = min(max(savedY + drag.height, 60), geo.size.height - 60)
                            drag = .zero
                        }
                )
            }
        }
        .allowsHitTesting(enabled)
    }
}
