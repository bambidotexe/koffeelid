import CryptoKit
import Foundation
import KoffeeLidCore

/// The two requests the update feature makes: GitHub's latest release, and that release's disk image.
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

    /// `KOFFEELID_UPDATE_FEED` points a build at a stand-in for GitHub's reply (a `file://` or `http://` URL of a
    /// latest-release JSON), which is how the whole update is exercised without publishing a release.
    static var feedURL: URL {
        ProcessInfo.processInfo.environment["KOFFEELID_UPDATE_FEED"].flatMap(URL.init(string:)) ?? UpdateCheck.latestReleaseAPI
    }

    /// A URLSession data task against `feedURL`; the completion always runs on main.
    func check(completion: @escaping (Result<UpdateDecision, Error>) -> Void) {
        var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
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
}

/// One fetch of a release's disk image into a folder, reporting its progress. The finished file is held against
/// what GitHub said about the asset (its length, its SHA-256) before anyone is told it is there: a download cut
/// short or altered on the way never reaches the disk image tools. Both callbacks run on main; after `cancel()`
/// neither runs again.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    enum DownloadError: LocalizedError {
        case damaged
        var errorDescription: String? { L("The download is damaged.") }
    }

    private let release: LatestRelease
    private let destination: URL
    private let onProgress: (Int64, Int64) -> Void
    private let onDone: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private let lock = NSLock()
    private var finished = false

    init(release: LatestRelease, destination: URL, onProgress: @escaping (Int64, Int64) -> Void, onDone: @escaping (Result<URL, Error>) -> Void) {
        self.release = release; self.destination = destination; self.onProgress = onProgress; self.onDone = onDone
    }

    func start() {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: release.dmgURL).resume()
    }

    func cancel() {
        guard claimEnd() else { return }
        session?.invalidateAndCancel()
    }

    /// True for the first caller only: a download ends once, by finishing, failing or being cancelled.
    private func claimEnd() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    private func end(_ result: Result<URL, Error>) {
        guard claimEnd() else { return }
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.onDone(result) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async { [self] in
            lock.lock(); let over = finished; lock.unlock()
            if !over { onProgress(totalBytesWritten, totalBytesExpectedToWrite) }
        }
    }

    /// The temporary file is gone once this returns, so it is moved and checked here, on the session's queue.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // A download task reports success on a 404 and hands over the error page it was served.
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateChecker.CheckError.httpStatus(http.statusCode)
            }
            let files = FileManager.default
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: destination)
            try files.moveItem(at: location, to: destination)
            guard try Self.matches(release, file: destination) else {
                try? files.removeItem(at: destination)
                throw DownloadError.damaged
            }
            end(.success(destination))
        } catch {
            end(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { end(.failure(error)) }
    }

    /// Whatever GitHub stated about the asset has to hold; what it did not state is not held against the file.
    static func matches(_ release: LatestRelease, file: URL) throws -> Bool {
        if let size = release.dmgSize {
            let actual = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
            guard actual == size else { return false }
        }
        guard let expected = release.dmgSHA256 else { return true }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
}
