//
//  EmotrixView.swift
//  Emotrix
//

import ScreenSaver
import AppKit

@objc(EmotrixView)
final class EmotrixView: ScreenSaverView {

    private var engine: MatrixEngine?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        DistributedNotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        // Must match MatrixEngine fps (currently 20)
        animationTimeInterval = 1.0 / 20.0

        // If macOS fails to call stopAnimation(),
        // still force cleanup when we receive stop notifications.
        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self,
                        selector: #selector(screenSaverWillStop(_:)),
                        name: Notification.Name("com.apple.screensaver.willstop"),
                        object: nil)
        dnc.addObserver(self,
                        selector: #selector(screenSaverDidStop(_:)),
                        name: Notification.Name("com.apple.screensaver.didstop"),
                        object: nil)
    }

    private func rebuildEngine() {
        let e = MatrixEngine(bounds: bounds)

        if let url = Bundle(for: EmotrixView.self).url(forResource: "sentences", withExtension: "txt") {
            e.loadSentences(from: url)
        }
        engine = e
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        engine?.resize(to: NSRect(origin: .zero, size: newSize))
    }

    override func startAnimation() {
        super.startAnimation()
        if engine == nil {
            rebuildEngine()
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        // drop resources immediately
        engine = nil
    }

    override func animateOneFrame() {
        setNeedsDisplay(bounds)
    }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        engine?.stepAndDraw(in: ctx)
    }

    // MARK: - Stop handling

    @objc private func screenSaverWillStop(_ n: Notification) {
        hardStopAndExit()
    }

    @objc private func screenSaverDidStop(_ n: Notification) {
        hardStopAndExit()
    }

    private func hardStopAndExit() {
        // Ensure we drop memory first
        engine = nil

        // Force-terminate the host
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exit(0)
        }
    }
}
