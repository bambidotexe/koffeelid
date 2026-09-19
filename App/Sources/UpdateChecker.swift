import AppKit
import KoffeeLidCore

/// A manual "check for updates" against GitHub releases: no background checking, no self-install. The user
/// presses a button; a newer release offers a second button that downloads the DMG and opens it (macOS mounts
/// it and shows the volume with its Applications link).
final class UpdateChecker {
    enum CheckError: LocalizedError {
        case httpStatus(Int)
        case malformedResponse
        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return String(format: L("Server returned status %d."), code)
            case .malformedResponse: return L("The release information could not be read.")
            }
        }
    }

    /// A URLSession data task against `UpdateCheck.latestReleaseAPI`; the completion always runs on main.
    func check(completion: @escaping (Result<UpdateDecision, Error>) -> Void) {
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<UpdateDecision, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(CheckError.httpStatus(http.statusCode))
            } else if let data, let latest = LatestRelease.parse(data) {
                result = .success(UpdateCheck.decide(current: KoffeeLidCore.version, latest: latest))
            } else {
                result = .failure(CheckError.malformedResponse)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(.upToDate): DiagnosticLog.shared.log("update check: up to date (\(KoffeeLidCore.version))")
                case .success(.available(let release)): DiagnosticLog.shared.log("update check: \(release.version.displayString) available")
                case .failure(let error): DiagnosticLog.shared.log("update check FAILED: \(error.localizedDescription)")
                }
                completion(result)
            }
        }
        task.resume()
    }

    /// A URLSession download task; moves the DMG into `<Application Support>/KoffeeLid/updates/` (removing
    /// any older DMG there first) and opens it with `NSWorkspace`. The completion always runs on main.
    func download(_ release: LatestRelease, completion: @escaping (Result<URL, Error>) -> Void) {
        let task = URLSession.shared.downloadTask(with: release.dmgURL) { tempURL, _, error in
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                guard let tempURL else { throw CheckError.malformedResponse }
                let updatesDir = AppSupport.directory.appendingPathComponent("updates", isDirectory: true)
                try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
                if let existing = try? FileManager.default.contentsOfDirectory(at: updatesDir, includingPropertiesForKeys: nil) {
                    for file in existing where file.pathExtension == "dmg" { try? FileManager.default.removeItem(at: file) }
                }
                let destination = updatesDir.appendingPathComponent("KoffeeLid-\(release.version.displayString).dmg")
                try FileManager.default.moveItem(at: tempURL, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    DiagnosticLog.shared.log("update: downloaded \(url.path); opening")
                    NSWorkspace.shared.open(url)
                    completion(.success(url))
                case .failure(let error):
                    DiagnosticLog.shared.log("update download FAILED: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
        task.resume()
    }
}
