import AppKit
import KoffeeLidCore

/// The update feature's one owner. It looks for a release on its own (`UpdateSchedule`: shortly after launch, then
/// weekly) and when the Settings button asks; a release found without being asked for is announced by a
/// notification. Update, from the notification or from Settings, opens one window that fetches the release and
/// makes it ready while the app is still running; "Install and Relaunch" then hands two folders to a helper and
/// quits the app the way the menu's Quit does. The rules are Core's (`UpdatePanel`, `UpdateSession`,
/// `StagedUpdateCheck`, `UpdateInstallScript`); this object runs the requests and words the answers.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    /// Settings › General › Updates.
    @Published private(set) var panel = UpdatePanel()
    /// The update window; nil while there is none.
    @Published private(set) var session: UpdateSession?
    /// Why the last click on Install and Relaunch was refused, shown in the window until the next click.
    @Published private(set) var refusal: String?
    /// How the last Install and Relaunch ended, from this launch until the user closes the window that says so.
    @Published private(set) var outcome: UpdateResult?

    var onShowSettings: (() -> Void)?
    /// Whether another window still needs the app active once the update window goes away.
    var othersNeedUsActive: () -> Bool = { false }
    /// A reason this is not the moment to quit the app, or nil. Asked at every click on Install and Relaunch.
    var installRefusal: (() -> String?)?
    /// Called once the helper is started, just before the app is asked to quit.
    var willQuitForInstall: (() -> Void)?

    static let directory = AppSupport.directory.appendingPathComponent("updates", isDirectory: true)
    private static var resultFile: URL { directory.appendingPathComponent("result") }

    /// Whether an install has left an outcome this launch has not read yet. The launch that follows an
    /// install is the helper's doing, not a person's, so it opens the window that says how it ended and
    /// nothing else. Read without touching anything: `readLastInstall` is what consumes it.
    static var installOutcomeIsWaiting: Bool {
        guard let written = (try? FileManager.default.attributesOfItem(atPath: resultFile.path)[.modificationDate]) as? Date
        else { return false }
        return UpdateResult.isNews(age: Date().timeIntervalSince(written))
    }

    private let log = DiagnosticLog.shared
    private let checker = UpdateChecker()
    private var schedule = UpdateSchedule()
    private var checkInFlight = false
    /// A press arrived while a check nobody had asked for was in flight: its answer is now awaited.
    private var answerIsAwaited = false
    /// The notification was clicked before this run had asked GitHub: the answer opens the window.
    private var presentWhenFound = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var download: UpdateDownload?
    /// Bumped whenever a session ends or starts over, so that a fetch or an unpacking that ends late is dropped.
    private var generation = 0
    private var diskImage: URL?
    private var stagedApp: URL?
    /// The install helper, from the click on Install and Relaunch until this app quits or gives up on quitting.
    private var helper: Int32?
    private var window: UpdateWindowController?
    /// One unpacking at a time: two would share the mount point and the `staged` folder, and a Cancel followed
    /// at once by Update starts a second while the first is still winding down.
    private static let stagingQueue = DispatchQueue(label: "dev.rubens.koffeelid.update.staging", qos: .userInitiated)

    var windowIsUp: Bool { window?.isUp == true }

    // MARK: Launch

    /// Reads how the last Install and Relaunch ended, then starts the schedule.
    func start() {
        readLastInstall()
        NotificationsController.shared.onUpdateRequested = { [weak self] in self?.presentUpdate() }
        timer = Timer.scheduledTimer(withTimeInterval: UpdateSchedule.launchDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick()
                self.timer = Timer.scheduledTimer(withTimeInterval: UpdateSchedule.tick, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                self.timer?.tolerance = 60
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The helper's one line. It is renamed rather than removed: the helper, which may still be watching this
    /// launch, reads that mark as "the new version had started" if the app is gone again a moment later. A line
    /// older than `UpdateResult.shelfLife` was left behind by an install nobody is waiting on any more.
    private func readLastInstall() {
        let files = FileManager.default
        let mark = UpdateResult.readMark(for: Self.resultFile)
        try? files.removeItem(at: mark)
        let line = try? String(contentsOf: Self.resultFile, encoding: .utf8)
        let written = (try? files.attributesOfItem(atPath: Self.resultFile.path)[.modificationDate]) as? Date
        try? files.moveItem(at: Self.resultFile, to: mark)
        sweep()
        guard let line else { return }
        guard let written, UpdateResult.isNews(age: Date().timeIntervalSince(written)) else {
            log.log("update: an install result left behind is ignored: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        switch UpdateResult(line: line) {
        case .installed(let version):
            log.log("update: version \(version) installed")
            present(.installed(version: version))
        case .failed(let version, let reason):
            log.log("update: version \(version) NOT installed (\(reason.rawValue)); still \(KoffeeLidCore.version)")
            panel.installFailed(Self.words(for: reason))
            present(.failed(version: version, reason: reason))
        case nil:
            log.log("update: unreadable install result: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Checks

    private func tick() {
        guard !checkInFlight, session == nil, schedule.isDue(now: Date()) else { return }
        runCheck(asked: false)
    }

    /// The Settings button.
    func press() {
        switch panel.press() {
        case .check:
            if checkInFlight { answerIsAwaited = true } else { runCheck(asked: true) }
        case .update(let release):
            begin(release)
        case nil:
            break
        }
    }

    private func runCheck(asked: Bool) {
        checkInFlight = true
        checker.check { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkInFlight = false
                let asked = asked || self.answerIsAwaited
                self.answerIsAwaited = false
                switch result {
                case .success(let decision):
                    self.schedule.answered(at: Date())
                    if asked {
                        self.panel.checked(decision)
                    } else {
                        self.panel.autoChecked(decision)
                        if case .available(let release) = decision {
                            NotificationsController.shared.postUpdateAvailable(version: release.version.displayString)
                        }
                    }
                case .failure(let error):
                    self.schedule.failed(at: Date())
                    if asked { self.panel.checkFailed(error.localizedDescription) }
                }
                guard self.presentWhenFound else { return }
                self.presentWhenFound = false
                if let release = self.panel.pendingRelease { self.begin(release) } else { self.onShowSettings?() }
            }
        }
    }

    // MARK: The update window

    /// The notification's Update, and a click on the notification itself. Same thing as the Settings button once it
    /// reads Update; a notification left by an earlier run asks GitHub first, then opens the window on the answer.
    func presentUpdate() {
        if session != nil { showWindow(); return }
        guard let release = panel.pendingRelease else {
            presentWhenFound = true
            press()
            return
        }
        begin(release)
    }

    private func begin(_ release: LatestRelease) {
        if session == nil {
            session = UpdateSession(release: release)
            refusal = nil
            outcome = nil
            startDownload(release)
        }
        showWindow()
    }

    private func showWindow() {
        if window == nil { window = UpdateWindowController(controller: self) }
        window?.show()
    }

    /// The window that asked for the update says how it ended, at the launch that follows it. It is the whole
    /// news: no other window opens behind it, and the app is otherwise back exactly as it was.
    private func present(_ outcome: UpdateResult) {
        self.outcome = outcome
        showWindow()
    }

    /// The button on that window.
    func dismissOutcome() {
        outcome = nil
        window?.close()
    }

    private func startDownload(_ release: LatestRelease) {
        generation += 1
        let current = generation
        sweep()
        let destination = Self.directory.appendingPathComponent("KoffeeLid-\(release.version.displayString).dmg")
        log.log("update: downloading \(release.dmgURL.absoluteString)")
        let download = UpdateDownload(release: release, destination: destination, onProgress: { [weak self] received, expected in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.session?.received(received, of: expected)
            }
        }, onDone: { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.downloadEnded(result)
            }
        })
        self.download = download
        download.start()
    }

    private func downloadEnded(_ result: Result<URL, Error>) {
        download = nil
        switch result {
        case .failure(let error):
            log.log("update download FAILED: \(error.localizedDescription)")
            session?.failed(error.localizedDescription)
        case .success(let image):
            log.log("update: downloaded \(image.path)")
            diskImage = image
            session?.downloaded()
            if let obstacle = UpdateInstaller.obstacle(updatesDirectory: Self.directory) {
                log.log("update: the app cannot replace itself here (\(obstacle.rawValue)); the disk image is the way")
                session?.cannotReplace()
            } else {
                prepare(image)
            }
        }
    }

    /// Unpacks and checks the release off the main thread; only a copy that passed everything enables the button.
    private func prepare(_ image: URL) {
        let current = generation
        let directory = Self.directory
        let stager = UpdateStager(bundleIdentifier: Bundle.main.bundleIdentifier ?? "", runningVersion: KoffeeLidCore.version,
                                  log: { line in DispatchQueue.main.async { DiagnosticLog.shared.log(line) } })
        Self.stagingQueue.async {
            let outcome = Result { try stager.stage(diskImage: image, in: directory) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Cancelled meanwhile: what it unpacked is swept when the next fetch starts, never here, where
                    // a later unpacking may already be filling the same folder.
                    guard self.generation == current else { return }
                    switch outcome {
                    case .success(let staged):
                        self.stagedApp = staged
                        self.session?.prepared()
                        self.log.log("update: ready to install")
                    case .failure(let error):
                        self.log.log("update: preparing FAILED: \(error)")
                        self.session?.failed(Self.words(for: error))
                    }
                }
            }
        }
    }

    func retry() {
        guard var current = session, current.retry() else { return }
        session = current
        refusal = nil
        startDownload(current.release)
    }

    /// Cancel, and the window's close button.
    func cancel() {
        guard let current = session, current.canCancel else { return }
        endSession(sweeping: true)
        log.log("update: cancelled")
        window?.close()
    }

    /// The window is going away on its own (its close button).
    func windowClosed() {
        if session?.canCancel == true {
            endSession(sweeping: true)
            log.log("update: cancelled")
        }
        outcome = nil
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    /// The way out when the app cannot replace itself: macOS mounts the image and shows its Applications link.
    func openDiskImage() {
        guard let image = diskImage else { return }
        log.log("update: opening \(image.path)")
        NSWorkspace.shared.open(image)
        endSession(sweeping: false)
        window?.close()
    }

    private func endSession(sweeping: Bool) {
        generation += 1
        download?.cancel()
        download = nil
        session = nil
        refusal = nil
        stagedApp = nil
        diskImage = nil
        if sweeping { sweep() }
    }

    /// What a fetch leaves behind. Never `previous`, which the helper may still need to put back, and never
    /// `mount`, which belongs to the unpacking that made it.
    private func sweep() {
        let files = FileManager.default
        for item in (try? files.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "dmg" || item.lastPathComponent == "staged" || item.lastPathComponent == "install.sh" {
            try? files.removeItem(at: item)
        }
    }

    // MARK: Install and Relaunch

    func installAndRelaunch() {
        guard let current = session, current.canInstall, let staged = stagedApp else { return }
        if let reason = installRefusal?() {
            refusal = reason
            log.log("update: install refused: \(reason)")
            return
        }
        refusal = nil
        let bundle = Bundle.main.bundleURL
        guard FileManager.default.fileExists(atPath: staged.path), UpdateInstaller.obstacle(updatesDirectory: Self.directory) == nil else {
            log.log("update: the prepared copy is gone or the app can no longer be replaced")
            session?.failed(Self.words(for: .replace))
            return
        }
        let plan = UpdateInstallPlan(pid: getpid(), destination: bundle, staged: staged,
                                     backup: Self.directory.appendingPathComponent("previous/\(bundle.lastPathComponent)"),
                                     resultFile: Self.resultFile, logFile: Self.directory.appendingPathComponent("install.log"),
                                     executableName: Bundle.main.executableURL?.lastPathComponent ?? "KoffeeLid",
                                     version: current.release.version.displayString)
        do { helper = try UpdateInstaller.start(plan, script: Self.directory.appendingPathComponent("install.sh")) }
        catch {
            log.log("update: the install helper could not be started: \(error)")
            session?.failed(Self.words(for: .replace))
            return
        }
        _ = session?.install()
        log.log("update: installing \(plan.version); quitting")
        // An app that is still here after `stallNotice` stops the helper before it says so, so that a quit
        // that comes later is only ever a quit. What was prepared is still good.
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateInstallPlan.stallNotice) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session?.phase == .installing else { return }
                if let helper = self.helper { UpdateInstaller.stop(helper) }
                self.helper = nil
                self.log.log("update: the app did not quit; helper stopped, install abandoned")
                self.session?.installStalled()
            }
        }
        willQuitForInstall?()
        // The menu's Quit: `applicationShouldTerminate` runs the coordinator's `shutdown()`.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: Words

    static func words(for reason: UpdateResult.Reason) -> String {
        switch reason {
        case .replace: return L("The new version could not be put in place.")
        case .launch: return L("The new version did not start, so the previous one was put back.")
        case .stranded: return L("The new version did not start and the previous one could not be put back. Download KoffeeLid again.")
        }
    }

    static func words(for error: Error) -> String {
        guard let error = error as? UpdateStager.StagingError else { return error.localizedDescription }
        switch error {
        case .cannotOpenImage: return L("The disk image could not be opened.")
        case .appMissing: return L("The disk image does not contain KoffeeLid.")
        case .rejected(.wrongApp): return L("The disk image does not contain KoffeeLid.")
        case .rejected(.notNewer): return L("The disk image does not hold a newer version.")
        case .rejected(.needsNewerSystem(let system)): return String(format: L("This version needs macOS %@ or later."), system)
        case .signature(.differentSigner): return L("The update is not signed by the same developer.")
        case .signature(.invalid): return L("The update’s signature is not valid.")
        }
    }
}
