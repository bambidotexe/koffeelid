import AppKit
import Combine
import SwiftUI
import KoffeeLidCore

/// The update window: the app's icon, the version being fetched, one line saying where things are, a bar, and
/// two buttons. It is as tall as what it says and keeps its top-left corner when that changes, like the Settings
/// window. Closing it is Cancel; while the install is under way it does not close.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 460

    private let window: NSWindow
    private let hosting: NSHostingController<UpdateView>
    private weak var controller: UpdateController?
    private var changes: AnyCancellable?
    private var hasBeenPlaced = false

    init(controller: UpdateController) {
        self.controller = controller
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Software Update")
        window.isReleasedWhenClosed = false
        hosting = NSHostingController(rootView: UpdateView(controller: controller))
        // The height is this class's to set: a hosting controller that also sizes the window grows it from the
        // bottom-left corner.
        hosting.sizingOptions = []
        super.init()
        window.contentViewController = hosting
        window.delegate = self
        // After the change, not during it: the view is measured with the new state in it.
        changes = controller.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(animated: true) } }
        }
    }

    var isUp: Bool { window.isVisible }

    func show() {
        if !hasBeenPlaced {
            fit(animated: false)
            window.center()
            hasBeenPlaced = true
        }
        // An accessory (menu-bar) app is never brought forward by the cooperative `activate()`.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    private func fit(animated: Bool) {
        let height = hosting.sizeThatFits(in: NSSize(width: Self.width, height: 2000)).height.rounded(.up)
        guard height > 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        guard frame.size != window.frame.size else { return }
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { controller?.session?.canCancel ?? true }

    func windowWillClose(_ notification: Notification) { controller?.windowClosed() }
}

struct UpdateView: View {
    @ObservedObject var controller: UpdateController

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        if let session = controller.session {
            // The app's name and version are not localized.
            shell(title: "KoffeeLid \(session.release.version.displayString)", status: status(of: session),
                  fraction: session.fraction, showsBar: showsBar(session), warning: warning(session)) {
                secondaryButton(session)
                primaryButton(session)
            }
        } else if let outcome = controller.outcome {
            shell(title: title(of: outcome), status: status(of: outcome), fraction: nil, showsBar: false, warning: nil) {
                Button(button(for: outcome)) { controller.dismissOutcome() }.prominent()
            }
        } else {
            Color.clear.frame(width: UpdateWindowController.width, height: 1)
        }
    }

    /// The window's one shape, whether it is fetching a release or saying how the last install ended.
    private func shell(title: String, status: String, fraction: Double?, showsBar: Bool, warning: String?,
                       @ViewBuilder buttons: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(status)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsBar { bar(fraction) }
                if let warning {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    buttons()
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: UpdateWindowController.width, alignment: .leading)
    }

    // MARK: How the last install ended

    /// The version that now runs: the new one when it was installed, the one that was kept when it was not.
    private func title(of outcome: UpdateResult) -> String {
        switch outcome {
        case .installed(let version): "KoffeeLid \(version)"
        case .failed: "KoffeeLid \(KoffeeLidCore.version)"
        }
    }

    private func status(of outcome: UpdateResult) -> String {
        switch outcome {
        case .installed: L("The update is installed. KoffeeLid is running the new version.")
        case .failed(let version, let reason):
            String(format: L("Version %@ was not installed. %@"), version, UpdateController.words(for: reason))
        }
    }

    private func button(for outcome: UpdateResult) -> String {
        switch outcome {
        case .installed: L("Done")
        case .failed: L("Close")
        }
    }

    // MARK: What it says

    private func status(of session: UpdateSession) -> String {
        switch session.phase {
        case .downloading(let received, let expected):
            guard let expected, expected > 0 else { return L("Downloading") }
            return String(format: L("Downloading: %@ of %@"), Self.bytes.string(fromByteCount: received), Self.bytes.string(fromByteCount: expected))
        case .preparing: return L("Preparing the update")
        case .ready: return L("Ready to install. KoffeeLid will quit and reopen.")
        case .manual: return L("KoffeeLid cannot replace itself where it is installed. Open the disk image and drag KoffeeLid to Applications, then quit and reopen it.")
        case .installing: return L("Installing")
        case .failed(let reason): return String(format: L("Update failed: %@"), reason)
        }
    }

    private func warning(_ session: UpdateSession) -> String? {
        if let refusal = controller.refusal { return refusal }
        return session.stalled ? L("KoffeeLid did not quit. Close its open dialogs, then try again.") : nil
    }

    private func showsBar(_ session: UpdateSession) -> Bool {
        switch session.phase {
        case .manual, .failed: false
        default: true
        }
    }

    @ViewBuilder private func bar(_ fraction: Double?) -> some View {
        if let fraction {
            ProgressView(value: fraction)
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }

    // MARK: The buttons

    @ViewBuilder private func secondaryButton(_ session: UpdateSession) -> some View {
        if case .failed = session.phase {
            Button(L("Close")) { controller.cancel() }.keyboardShortcut(.cancelAction)
        } else {
            Button(L("Cancel")) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(!session.canCancel)
        }
    }

    @ViewBuilder private func primaryButton(_ session: UpdateSession) -> some View {
        switch session.phase {
        case .failed:
            Button(L("Try Again")) { controller.retry() }.prominent()
        case .manual:
            Button(L("Open Disk Image")) { controller.openDiskImage() }.prominent()
        default:
            Button(L("Install and Relaunch")) { controller.installAndRelaunch() }
                .prominent()
                .disabled(!session.canInstall)
        }
    }
}

private extension View {
    /// The window's one main action, as in Settings: prominent and blue, and what Return presses.
    func prominent() -> some View {
        buttonStyle(.borderedProminent).tint(.blue).keyboardShortcut(.defaultAction)
    }
}
