import AppKit
import CoreGraphics
import KoffeeLidCore

/// Lifecycle of the lid-close effect.
///
/// `start()` (armed, lid open) only prepares: an invisible panel, a renderer, and a capture whose
/// shareable content is fetched ahead of time. Nothing is recorded. When the lid has closed
/// `foldThresholdDegrees` (the gesture's activation travel) past its rest angle (`FoldTracker`), a session
/// begins: an instant still, then the stream. The fold shown is `FoldGeometry` applied to the tracker's
/// zero angle: 1:1 with the lid below `gestureStartBelowDegrees` (the inner screen stands upright there,
/// 95° by default), so a gesture made above it shows nothing until the lid passes it, and a fold that
/// begins below it (the start-below gate) catches up with that curve.
/// The panel fades in with the first visible degree. When the fold returns to zero the session ends a
/// moment later. `stop()` tears everything down.
@MainActor
public final class EffectController {
    public var parameters: EffectParameters {
        didSet {
            let p = parameters.clamped()
            renderer?.parameters = p
            smoother.apply(responsiveness: p.responsiveness)
            tracker?.settleDelay = p.settleDelay
            tracker?.startBelowAngle = gateToStartAngle ? p.startBelowDegrees : nil
            geometry.uprightAngle = p.gestureStartBelowDegrees
            if !p.enabled, isRunning, simulation == nil { stop() }
        }
    }
    /// Closing travel from rest before the fold starts; the coordinator keeps it equal to the gesture's
    /// "Activation after" so the plane starts to move exactly when Option + close arms.
    public var foldThresholdDegrees: Double = 4 { didSet { tracker?.thresholdDegrees = foldThresholdDegrees } }
    public private(set) var isRunning = false
    /// True for arms that did not come from the Option + close gesture: the fold also waits for the lid
    /// to be below `startBelowDegrees`, so small adjustments while working never start it.
    public var gateToStartAngle = false { didSet { tracker?.startBelowAngle = gateToStartAngle ? parameters.clamped().startBelowDegrees : nil } }
    public private(set) var isCapturing = false
    public var onLog: ((String) -> Void)?
    public var onNeedsAngleSampling: ((Bool) -> Void)?

    private var panel: EffectOverlayPanel?
    private var renderer: PlaneRenderer?
    private var capture: DesktopCapture?
    private var tracker: FoldTracker?
    private var geometry: FoldGeometry
    private var smoother: AngleSmoother
    private var sessionEndTimer: Timer?
    private var simulation: (start: TimeInterval, degrees: Double, seconds: TimeInterval, timer: Timer, temporary: Bool)?
    private var lastAngle: Double?
    /// Set by `followLidFromHere()`; the gate it suspended comes back when that fold ends.
    private var followingLid = false
    public var isFollowingLid: Bool { followingLid }
    /// True while the plane is folded (the tracker has a fold in progress).
    public var isFolding: Bool { tracker?.isFolding == true }

    public enum FollowResult: Equatable { case notRunning, alreadyFollowing, keptCurrentFold, following }
    private var retraction: (start: TimeInterval, from: Double, timer: Timer, fading: Bool)?
    private static let sessionLinger: TimeInterval = 0.75
    /// The geometry needs cos(fold) > 0 and nobody can see the display past this; the plane freezes here.
    static let maxFoldDegrees: Double = 80
    private static let retractDuration: TimeInterval = 0.3

    public init(parameters: EffectParameters) {
        self.parameters = parameters
        smoother = AngleSmoother(responsiveness: parameters.clamped().responsiveness)
        geometry = FoldGeometry(uprightAngle: parameters.clamped().gestureStartBelowDegrees)
    }

    public static var builtInDisplayID: CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: armed / disarmed

    public func start() {
        if retraction != nil { tearDown() }
        guard !isRunning, parameters.enabled else { return }
        guard ScreenCapturePermission.isGranted else { onLog?("effect: screen recording not granted; effect stays off"); return }
        guard let displayID = Self.builtInDisplayID,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }),
              let renderer = PlaneRenderer(frame: CGRect(origin: .zero, size: screen.frame.size)) else {
            onLog?("effect: no built-in display or Metal unavailable"); return
        }
        renderer.parameters = parameters.clamped()
        renderer.angleProvider = { [weak self] in self?.currentFoldRadians() ?? 0 }
        renderer.onFirstFrameRendered = { [weak self] in self?.updateVisibility() }
        renderer.isPaused = true
        let panel = EffectOverlayPanel(screen: screen)
        panel.contentView = renderer
        panel.orderFrontRegardless()

        let capture = DesktopCapture(displayID: displayID, excludingWindowNumber: panel.windowNumber)
        capture.onFrame = { [weak renderer] buffer in renderer?.submit(pixelBuffer: buffer) }
        capture.onError = { [weak self] error in Task { @MainActor in self?.onLog?("effect: capture stopped: \(error.localizedDescription)"); self?.endSession(immediately: true) } }

        self.panel = panel; self.renderer = renderer; self.capture = capture
        tracker = nil; smoother.reset(); lastAngle = nil
        isRunning = true
        onNeedsAngleSampling?(true)
        Task { [weak self] in
            do { try await capture.prepare() }
            catch { await MainActor.run { self?.onLog?("effect: capture preparation failed: \(error.localizedDescription)") } }
        }
    }

    /// `retracting`: keep the plane on screen and ease it back flat over 0.3 s before tearing
    /// down (the user reopened the lid and cancelled); otherwise everything goes at once.
    public func stop(retracting: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        onNeedsAngleSampling?(false)
        simulation?.timer.invalidate(); simulation = nil
        sessionEndTimer?.invalidate(); sessionEndTimer = nil
        let now = ProcessInfo.processInfo.systemUptime
        let fold = smoother.value(at: now) ?? 0
        if retracting, isCapturing, renderer?.hasContent == true, fold > 0.5 {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickRetraction() }
            }
            retraction = (now, fold, timer, false)
            onLog?("effect: retracting from \(Int(fold))°")
            return
        }
        tearDown()
    }

    private func tickRetraction() {
        guard let r = retraction else { return }
        let t = min(1, (ProcessInfo.processInfo.systemUptime - r.start) / Self.retractDuration)
        let eased = 1 - (1 - t) * (1 - t) * (1 - t)          // ease-out cubic
        smoother.reset()
        smoother.feed(r.from * (1 - eased), at: 0)           // held value: read as-is by the renderer
        // Cross-fade out over the last part of the retraction instead of vanishing on the final frame.
        if t >= 0.6, !r.fading, let panel {
            retraction?.fading = true
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = Self.retractDuration * 0.45; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in Task { @MainActor in self?.tearDown() } })
        }
    }

    private func tearDown() {
        guard renderer != nil else { return }               // a re-arm may already have torn us down mid-fade
        retraction?.timer.invalidate(); retraction = nil
        let capture = self.capture
        Task { await capture?.stop() }
        if isCapturing { onLog?("effect: capture stopped") }
        isCapturing = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil; renderer = nil; self.capture = nil; tracker = nil; lastAngle = nil
        smoother.reset(); followingLid = false
        onLog?("effect: stopped")
    }

    // MARK: angle stream

    /// `changedAt`: system uptime at which the sensor first showed this value (`LidAngleObserver`); the
    /// tracker runs on the delivery time, the smoother on the change time. Defaults to now.
    /// `holding`: the gesture modifier is down — stillness does not ease the plane back to flat.
    public func feed(angleDegrees: Double, changedAt: TimeInterval? = nil, holding: Bool = false) {
        guard isRunning, simulation == nil else { lastAngle = angleDegrees; return }
        let now = ProcessInfo.processInfo.systemUptime
        let p = parameters.clamped()
        if tracker == nil {
            tracker = FoldTracker(angle: angleDegrees, now: now, thresholdDegrees: foldThresholdDegrees, settleDelay: p.settleDelay,
                                  startBelowAngle: gateToStartAngle ? p.startBelowDegrees : nil)
        }
        lastAngle = angleDegrees
        let change = tracker!.update(angle: angleDegrees, now: now, holding: holding)
        smoother.feed(geometry.fold(angle: angleDegrees, zeroAngle: tracker!.zeroAngle), at: changedAt ?? now)
        switch change {
        case .foldBegan?: beginSession()
        case .foldEnded?:
            endSession(immediately: false)
            if followingLid {
                // The Option + close fold is over (reopened, or settled flat): the menu arm's gate applies again.
                followingLid = false
                gateToStartAngle = true
                tracker?.rebase(angle: angleDegrees, now: now)
                onLog?("effect: gesture fold ended; waiting below \(Int(p.startBelowDegrees))° again")
            }
        case nil: break
        }
        updateVisibility()
    }

    /// Fn + close performed while already armed from the menu/shortcut/CLI: drop the absolute gate and make
    /// the current lid angle the fold's zero, so the plane follows the hand from this moment (visible from
    /// `gestureStartBelowDegrees`, `FoldGeometry`). If the gate already let a fold start, that fold is kept — rebasing would snap
    /// the plane flat under the user's hand. Idempotent while a gesture fold is running.
    @discardableResult
    public func followLidFromHere() -> FollowResult {
        guard isRunning else { return .notRunning }
        if followingLid { return .alreadyFollowing }
        followingLid = true
        gateToStartAngle = false
        guard let a = lastAngle, var t = tracker else { return .following }
        if t.isFolding {
            onLog?("effect: gesture while already folding; keeping the fold")
            return .keptCurrentFold
        }
        t.rebase(angle: a + t.thresholdDegrees, now: ProcessInfo.processInfo.systemUptime)
        tracker = t
        onLog?("effect: following the lid from \(Int(a))°")
        return .following
    }

    /// A 0 → `degrees` → 0 fold over `seconds`, for the Settings button. Works whether or not the Mac is
    /// armed: when the effect is not running it is started for the preview and torn down afterwards.
    public func simulateFold(degrees: Double = 35, seconds: TimeInterval = 2) {
        guard simulation == nil else { return }
        let temporary = !isRunning
        if temporary {
            let enabled = parameters.enabled
            if !enabled { parameters.enabled = true }          // preview must work even with the effect switched off
            start()
            if !enabled { parameters.enabled = false; if !isRunning { return } }
            guard isRunning else { onLog?("effect: cannot simulate (effect could not start)"); return }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSimulation() }
        }
        simulation = (start, degrees, seconds, timer, temporary)
        smoother.reset()
        beginSession()
        onLog?("effect: simulating a \(Int(degrees))° fold\(temporary ? " (preview, effect not running)" : "")")
    }

    private func tickSimulation() {
        guard let sim = simulation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let t = (now - sim.start) / sim.seconds
        if t >= 1 {
            sim.timer.invalidate(); simulation = nil
            smoother.reset()
            if sim.temporary { stop(); return }
            if let a = lastAngle { tracker?.rebase(angle: a, now: now) }
            endSession(immediately: false)
            return
        }
        smoother.feed(sim.degrees * sin(t * .pi), at: now)
        updateVisibility()
    }

    // MARK: sessions

    private func beginSession() {
        sessionEndTimer?.invalidate(); sessionEndTimer = nil
        guard !isCapturing, let capture, let renderer else { return }
        isCapturing = true
        renderer.isPaused = false
        Task { [weak self] in
            if let still = try? await capture.captureStill() { renderer.submit(image: still) }
            // The still can take hundreds of ms on a fresh arm, and a reopen cancel may have torn the session
            // down meanwhile. Starting now would stream into a capture nobody owns (the recording indicator
            // stays lit until quit), so the start only goes ahead while this session still owns this capture.
            let stillWanted = await MainActor.run { self?.isCapturing == true && self?.capture === capture }
            guard stillWanted else { return }
            do {
                try await capture.start()
                await MainActor.run { if self?.isCapturing == true { self?.onLog?("effect: capture started") } }
            } catch {
                await MainActor.run { self?.onLog?("effect: capture failed: \(error.localizedDescription)"); self?.endSession(immediately: true) }
            }
        }
    }

    private func endSession(immediately: Bool) {
        guard isCapturing else { return }
        if !immediately {
            sessionEndTimer?.invalidate()
            sessionEndTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionLinger, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isCapturing, self.tracker?.isFolding != true, self.simulation == nil else { return }
                    self.endSession(immediately: true)
                }
            }
            return
        }
        sessionEndTimer?.invalidate(); sessionEndTimer = nil
        isCapturing = false
        let capture = self.capture
        Task { await capture?.stop() }
        if let panel { panel.alphaValue = 0 }
        renderer?.clearContent()
        renderer?.isPaused = true
        onLog?("effect: capture stopped")
    }

    // MARK: rendering

    private func currentFoldRadians() -> Float {
        let fold = smoother.value(at: ProcessInfo.processInfo.systemUptime) ?? 0
        return Float(min(Self.maxFoldDegrees, max(0, fold)) * .pi / 180)
    }

    private func updateVisibility() {
        guard let panel, let renderer else { return }
        let active = isCapturing && renderer.hasContent && currentFoldRadians() > 0.002
        let target: CGFloat = active ? 1 : 0
        if panel.alphaValue != target {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = active ? 0.08 : 0.15; panel.animator().alphaValue = target }
        }
    }
}
