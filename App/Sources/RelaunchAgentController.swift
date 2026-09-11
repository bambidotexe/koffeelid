import Foundation
import ServiceManagement
import KoffeeLidCore

final class RelaunchAgentController {
    static let agentLabel = "dev.rubens.koffeelid.agent"
    private let service = SMAppService.agent(plistName: "dev.rubens.koffeelid.agent.plist")
    var onLog: ((String) -> Void)?
    var status: SMAppService.Status { service.status }

    func register() throws {
        guard status != .enabled, status != .requiresApproval else {
            onLog?("relaunch agent already registered (status \(status.rawValue))"); return
        }
        try service.register()
        onLog?("relaunch agent registered (status \(status.rawValue))")
    }
    func unregister() throws { try service.unregister(); onLog?("relaunch agent unregistered") }

    /// launchd keeps a registered agent loaded but does not necessarily keep it running
    /// (a crash with SuccessfulExit=false, a manual pkill, a stand-down exit). A kickstart
    /// without -k starts it if it is down and leaves a healthy one alone.
    func kickstartIfEnabled() {
        guard status == .enabled else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(Self.agentLabel)"]
        do {
            try p.run()
            p.waitUntilExit()
            onLog?("watchdog kickstart exited \(p.terminationStatus)")
        } catch {
            onLog?("watchdog kickstart failed to launch (\(error.localizedDescription))")
        }
    }

    func writePidFile() {
        let record = PidFileRecord(pid: getpid(), executablePath: Bundle.main.executablePath ?? "")
        do {
            try FileManager.default.createDirectory(at: AppSupport.directory, withIntermediateDirectories: true)
            try record.serialized.write(to: AppSupport.pidFileURL, atomically: true, encoding: .utf8)
        } catch { onLog?("pid file write failed: \(error.localizedDescription)") }
    }
    func removePidFile() { try? FileManager.default.removeItem(at: AppSupport.pidFileURL) }
}
