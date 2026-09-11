import Foundation
import CoreGraphics
import KoffeeLidCore

final class InternalDisplayBrightnessController {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getBrightness: GetFn?
    private let setBrightness: SetFn?
    private let recoveryURL: URL
    var onLog: ((String) -> Void)?
    var isAvailable: Bool { getBrightness != nil && setBrightness != nil }

    private struct Recovery: Codable { var displayID: UInt32; var brightness: Float }

    init(recoveryURL: URL = AppSupport.brightnessRecoveryURL) {
        self.recoveryURL = recoveryURL
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            getBrightness = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
            setBrightness = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        } else { getBrightness = nil; setBrightness = nil }
    }

    private var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0; var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func darken() -> Bool {
        guard let get = getBrightness, let set = setBrightness else { onLog?("DisplayServices brightness symbols unavailable; panel was not darkened"); return false }
        guard let id = builtInDisplay else { onLog?("built-in display brightness unavailable; panel was not darkened"); return false }
        var current: Float = 0
        guard get(id, &current) == 0 else { onLog?("built-in display brightness unavailable; panel was not darkened"); return false }
        do {
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Recovery(displayID: id, brightness: current)).write(to: recoveryURL, options: .atomic)
        } catch { onLog?("could not persist brightness recovery; refusing to darken"); return false }
        guard set(id, 0) == 0 else { onLog?("built-in display brightness set FAILED"); return false }
        var check: Float = 1
        guard get(id, &check) == 0, check <= 0.01 else { onLog?("built-in display brightness-zero verification FAILED"); return false }
        onLog?("built-in display brightness set to zero")
        return true
    }

    @discardableResult
    func restoreIfNeeded(reason: String) -> Bool {
        guard let data = try? Data(contentsOf: recoveryURL), let r = try? JSONDecoder().decode(Recovery.self, from: data) else { return true }
        guard let set = setBrightness else { onLog?("built-in display brightness restore FAILED (no DisplayServices)"); return false }
        guard set(r.displayID, r.brightness) == 0 else { onLog?("built-in display brightness restore FAILED (\(reason))"); return false }
        try? FileManager.default.removeItem(at: recoveryURL)
        onLog?("built-in display brightness restored (\(reason))")
        return true
    }

    static func displaySleepNow(onLog: ((String) -> Void)?) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]
        do { try p.run(); p.waitUntilExit(); onLog?("pmset displaysleepnow exited \(p.terminationStatus)") }
        catch { onLog?("pmset displaysleepnow failed to launch (\(error.localizedDescription))") }
    }
}
