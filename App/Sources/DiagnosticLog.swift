import Foundation
import KoffeeLidCore

final class DiagnosticLog {
    static let shared = DiagnosticLog(url: AppSupport.diagnosticsURL)
    let url: URL
    private let queue = DispatchQueue(label: "dev.rubens.koffeelid.diag", qos: .utility)
    private let writer: DiagnosticFileWriter

    init(url: URL) {
        self.url = url
        self.writer = DiagnosticFileWriter(url: url)
    }

    func log(_ message: String) {
        guard Preferences.shared.diagnosticsEnabled else { return }
        let line = DiagnosticLine.render(Date(), message)
        #if DEBUG
        NSLog("%@", message)
        #endif
        queue.async { [writer] in
            writer.append(line)
        }
    }

    /// Blocks until all previously enqueued log writes have completed.
    func flush() { queue.sync {} }
}
