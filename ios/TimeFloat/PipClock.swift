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

    /// KVO 观察 isPictureInPicturePossible：它变 true 的那一刻自动开画面，
    /// 这样用户点一次就能起（以前要等系统异步置位，所以要点两次）
    private var possibleObs: NSKeyValueObservation?
    /// 用户已经点了"启动"、正在等系统就绪
    private var wantStart = false
    /// 帧计数：画中画没开时降频，只维持 App 内预览
    private var tickCount = 0

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

    /// App 内的预览：进前台就先把时间基和帧循环准备好，让那个小预览框立刻显示时间
    /// （以前只在点「启动画中画」时才初始化，所以启动前预览是**全黑**的一块）
    func preparePreview() {
        guard Self.isSupported else { return }
        if timebase == nil { configureTimebase() }
        renderFrame(force: true)
        if timer == nil { startFrameLoop() }
    }

    func start() {
        guard Self.isSupported else {
            status = "此设备不支持画中画"
            return
        }

        // 关键：先把第一帧画出来。系统要求 displayLayer 里已经有内容，
        // isPictureInPicturePossible 才会变 true。
        configureAudioSessionIfNeeded()
        // ★ 时间基必须在第一帧之前建好：否则首帧 PTS 走的是 frameIndex 兜底值，
        //   与后续帧（走 timebase）不同基准 → PTS 倒退 → 启动瞬间黑一下。
        if timebase == nil { configureTimebase() }
        renderFrame(force: true)
        armStartTimeout()

        // 已经建过控制器：直接请求启动；此刻还没就绪就交给 KVO 补上
        if let p = pip {
            wantStart = true
            if p.isPictureInPicturePossible {
                wantStart = false
                p.startPictureInPicture()
            } else {
                status = "正在启动画中画…"
            }
            return
        }

        startFrameLoop()

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = false

        // ★ 系统就绪的瞬间自动开，用户不用点第二次
        possibleObs = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] c, _ in
            guard let self = self else { return }
            if c.isPictureInPicturePossible && self.wantStart {
                self.wantStart = false
                c.startPictureInPicture()
            }
        }

        pip = controller
        wantStart = true
        if controller.isPictureInPicturePossible {
            wantStart = false
            controller.startPictureInPicture()
            status = "画中画已就绪"
        } else {
            status = "正在启动画中画…"
        }
    }

    /// 关闭：如果正在画中画，交给 delegate 收尾（不要在这里 invalidate 定时器，
    /// 否则画面会在关闭动画期间变黑）
    func stop() {
        wantStart = false
        if let p = pip, p.isPictureInPictureActive {
            p.stopPictureInPicture()
            status = "正在关闭…"
        } else {
            finishStop()
        }
    }

    private func finishStop() {
        timer?.invalidate()
        timer = nil
        possibleObs?.invalidate()
        possibleObs = nil
        pip = nil
        isActive = false
        status = "已关闭"
    }

    /// 兜底提示：正常情况 KVO 会在几百毫秒内把画中画拉起来，
    /// 3 秒还没动就说明这次没成，直接告诉用户（免得又出现"点了没反应"）
    private func armStartTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if self.wantStart && !self.isActive {
                self.wantStart = false
                self.status = "启动超时，请再点一次"
            }
        }
    }

    private var audioConfigured = false

    private func configureAudioSessionIfNeeded() {
        guard !audioConfigured else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            audioConfigured = true
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

    private func renderFrame(force: Bool = false) {
        frameIndex += 1
        tickCount += 1
        // 画中画开着时 15fps；没开时降频，只维持 App 内那个小预览（省电，不空转）
        let pipActive = pip?.isPictureInPictureActive ?? false
        if !force && !pipActive && tickCount % 8 != 1 { return }
        // 退到后台又没开画中画：预览根本看不见，别画了
        if !pipActive && UIApplication.shared.applicationState == .background { return }
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
        // ★ 消费端跟不上就直接丢掉这一帧（时钟只要最新一帧，丢帧天然是正确的），
        //   否则 CMSampleBuffer 会在图层里堆积 → 内存上涨，flush 那一瞬间画面闪一下。
        guard displayLayer.isReadyForMoreMediaData else { return }

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
        // ★ 标记「立即显示」：不设这个，displayLayer 会按 PTS 排队显示，
        //   毫秒时钟会出现约一帧的滞后和偶发丢帧（浮窗上看就是"顿一下"）。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
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
        // ★ 必须是 false。本 App 在后台还能继续走，靠的就是 active 的 audio session +
        //   UIBackgroundModes=[audio]；返回 true（= 禁止后台音频播放）有被系统判成
        //   "播放已暂停"的风险 → 时间基 rate 归零 → 切到别的 App 后浮窗时间停在最后一帧。
        //   我们本来就没有任何音频需要"禁止"，false 是零成本且方向安全的选择。
        false
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PipClockRenderer: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        wantStart = false
        isActive = true
        status = "悬浮中（画中画窗口）"
    }

    /// ★ 苹果文档明确要求：这里必须尽快回调 completionHandler(true)，
    /// 否则系统要等约 1 秒超时才会真正收起浮窗 —— 这就是"关闭要转圈一秒"的原因。
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        status = "画中画已收起"
        // 用户点浮窗上的 X 也会走到这里；定时器留着继续给 App 内预览降频重绘
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        wantStart = false
        isActive = false
        status = "画中画启动失败：\(error.localizedDescription)"
    }
}

/// 把 AVSampleBufferDisplayLayer 挂到 SwiftUI 的宿主 UIView。
/// 界面上不显示预览，它只是让渲染层待在视图树里（见 ContentView 里 0 透明度的用法）。
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

struct PipLayerHost: UIViewRepresentable {
    let renderer: PipClockRenderer

    func makeUIView(context: Context) -> SampleBufferHostView {
        SampleBufferHostView(displayLayer: renderer.displayLayer)
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {}
}
