import AVFoundation
import AVKit
import CoreMedia
import UIKit
import SwiftUI

/// 苹果官方能力说明（查过 developer.apple.com）：
///  · iOS 不给第三方 App 提供"任意置顶悬浮窗"API，UIWindow.Level 只在本 App 的 scene 内生效；
///  · 唯一能浮在别的 App 之上的是画中画：
///    AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)  (iOS 15.0+)
///    窗口由系统提供，可拖动，不属于任何 App 的界面层级；
///  · 需要音频后台模式（UIBackgroundModes = audio）+ active 的 AVAudioSession(.playback)。
///
/// 本类把**选中的那一路时间**画进 CVPixelBuffer，再用 CMSampleBuffer 喂给
/// AVSampleBufferDisplayLayer，15fps 刷新，浮窗里就是毫秒级时间。
final class PipClockRenderer: NSObject, ObservableObject {

    /// 画中画里文字若上下颠倒，把这里改成 false（不同 iOS 版本对 pixelBuffer 方向约定略有差异）
    static let flipVertically = true

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    let displayLayer = AVSampleBufferDisplayLayer()

    @Published var isActive = false
    @Published var status = "未开启"

    private var pip: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var timer: Timer?
    private var pool: CVPixelBufferPool?
    private var frameIndex: Int64 = 0

    private let renderSize = CGSize(width: 660, height: 240)
    private let fps: Int32 = 15

    /// 由外部提供当前要显示的时钟（选中的那一路）
    private let clockProvider: () -> ServerClock

    init(clock: @escaping () -> ServerClock) {
        self.clockProvider = clock
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    // MARK: - 生命周期

    func start() {
        guard Self.isSupported else {
            status = "此设备不支持画中画"
            return
        }
        if let p = pip {
            p.startPictureInPicture()
            return
        }
        configureAudioSession()
        configureTimebase()

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = false
        pip = controller

        startFrameLoop()
        status = "画中画已就绪"
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            status = "切到别的 App 会自动浮起来（或稍后再点一次）"
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let p = pip, p.isPictureInPictureActive { p.stopPictureInPicture() }
        pip = nil
        isActive = false
        status = "已关闭"
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            status = "音频会话设置失败：\(error.localizedDescription)"
        }
    }

    private func configureTimebase() {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        guard let tb = tb else { return }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 1)
        timebase = tb
        displayLayer.controlTimebase = tb
    }

    private func startFrameLoop() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            self?.renderFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 逐帧绘制

    private func renderFrame() {
        frameIndex += 1
        guard let pixelBuffer = makePixelBuffer() else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                  width: Int(w), height: Int(h),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        // 背景：深色渐变
        ctx.setFillColor(UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        if Self.flipVertically {
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
        }
        UIGraphicsPushContext(ctx)
        draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        UIGraphicsPopContext()

        enqueue(pixelBuffer)
    }

    private func draw(in rect: CGRect) {
        let clock = clockProvider()
        let accent = UIColor(clock.accentColor)

        // 只画「服务器名 + 时间」，别的一律不要
        let statusUIColor: UIColor
        switch clock.statusColor {
        case .green: statusUIColor = .systemGreen
        case .yellow: statusUIColor = .systemYellow
        default: statusUIColor = .systemRed
        }
        statusUIColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: 22, y: 24, width: 13, height: 13)).fill()

        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: accent
        ]
        (clock.label + "服务器时间" as NSString).draw(at: CGPoint(x: 46, y: 19), withAttributes: nameAttr)

        // 大字时间（没校上时用占位符，不拿墙钟冒充）
        // 自适应：先按 92pt 排，若超出画布可用宽度就等比缩小，保证毫秒三位永远完整
        let t = clock.utcMsOrNil()
        let timeText = (t.map { Fmt.hms($0) } ?? "--:--:--.---") as NSString
        let maxWidth = rect.width - 40
        var fontSize: CGFloat = 92
        var timeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: t == nil ? UIColor.systemYellow : UIColor.white
        ]
        var timeSize = timeText.size(withAttributes: timeAttr)
        if timeSize.width > maxWidth && timeSize.width > 0 {
            fontSize = max(40, fontSize * maxWidth / timeSize.width)
            timeAttr[.font] = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            timeSize = timeText.size(withAttributes: timeAttr)
        }
        timeText.draw(at: CGPoint(x: (rect.maxX - timeSize.width) / 2,
                                  y: (rect.maxY - timeSize.height) / 2 + 16),
                      withAttributes: timeAttr)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p
        }
        guard let pool = pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let formatDesc = format else { return }

        let pts = timebase.map { CMTimebaseGetTime($0) } ?? CMTime(value: frameIndex, timescale: fps)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                imageBuffer: pixelBuffer,
                                                formatDescription: formatDesc,
                                                sampleTiming: &timing,
                                                sampleBufferOut: &sampleBuffer)
        guard let sb = sampleBuffer else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sb)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate（iOS 15.0+，官方要求的 6 个方法）

extension PipClockRenderer: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool {
        true
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PipClockRenderer: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
        status = "悬浮中（画中画窗口）"
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        status = "画中画已收起"
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        status = "画中画启动失败：\(error.localizedDescription)"
    }
}

/// 把 AVSampleBufferDisplayLayer 挂到 SwiftUI 里的宿主 UIView
final class SampleBufferHostView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        layer.addSublayer(displayLayer)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

struct PipPreviewView: UIViewRepresentable {
    let renderer: PipClockRenderer

    func makeUIView(context: Context) -> SampleBufferHostView {
        SampleBufferHostView(displayLayer: renderer.displayLayer)
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {}
}
