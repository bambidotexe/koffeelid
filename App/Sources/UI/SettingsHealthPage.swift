import AppKit
import SwiftUI
import KoffeeLidCore

/// Whether KoffeeLid is doing its job, at a glance: one overview row that sums the page up, then every state
/// that bears on it, grouped by subject, each a `StatusRow` in the colour of its level. It reports and
/// changes nothing: a state is put right on the page that owns it, and each orange or red row says where in
/// a warning under its group.
///
/// What goes here, what does not (the version and updates stay on General), and which colour a state takes
/// are the `macos-building-settings-pages` skill's *The Health page*. The rows themselves are decided in
/// `HealthReport` (Core), where they are tested; `HealthWords` puts them in words and this view draws them.
/// The readings are `HealthCheck`'s, taken by the window, never by this view.
struct SettingsHealthPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var health: HealthCheck

    var body: some View {
        let groups = HealthWords.groups(HealthReport.sections(for: health.facts(model)))
        let summary = HealthSummary(groups: groups)
        SettingsPage {
            SettingsGroup(title: L("Overview")) {
                // The app's name is not localized.
                StatusRow("KoffeeLid",
                          mark: health.isChecking
                            ? .busy(L("Checking"))
                            : StatusMark(StatusSeverity(summary.level), HealthWords.summary(summary)))
                ButtonRow {
                    Button(L("Check Again")) { health.checkAgain(model) }
                        .disabled(health.isChecking)
                }
            }
            ForEach(groups) { group in
                SettingsGroup(title: group.title, hint: group.hint, warnings: group.warnings) {
                    ForEach(group.rows) { row in
                        HealthRowView(row: row)
                    }
                }
            }
            SettingsGroup(title: L("Report"),
                          hint: L("Copies everything on this page as text, to paste into a bug report.")) {
                ButtonRow {
                    Button(L("Copy Report")) { copyReport(groups, summary: summary) }
                }
            }
        }
    }

    private func copyReport(_ groups: [HealthGroup], summary: HealthSummary) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let text = HealthReport.text(appName: "KoffeeLid", version: KoffeeLidCore.version,
                                     system: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                     summary: HealthWords.summary(summary), groups: groups)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One row of the page: the kit's `StatusRow`, and what only a bug report needs as its tooltip.
private struct HealthRowView: View {
    let row: HealthRow

    var body: some View {
        if let detail = row.detail, !detail.isEmpty {
            StatusRow(row.label, mark: StatusMark(StatusSeverity(row.level), row.word)).help(detail)
        } else {
            StatusRow(row.label, mark: StatusMark(StatusSeverity(row.level), row.word))
        }
    }
}
