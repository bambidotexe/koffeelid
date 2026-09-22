import SwiftUI
import KoffeeLidCore

/// Whether KoffeeLid works, at a glance: two tables and nothing else. **Health** holds the checks, each
/// green, orange or red, with Check Again under them and, while a line is orange or red, the sentence that
/// says where to put it right. **Information** holds a few readings, blue. The page reports and changes
/// nothing: a state is put right on the page that owns it.
///
/// What is a check, what is a reading, what goes on neither (a preference, the version, updates, the battery)
/// and how long each table may be are the `macos-building-settings-pages` skill's *The Health page*. The
/// lines are decided in `HealthReport` (Core), where they are tested; `HealthWords` puts them in words and
/// this view draws them. The readings are `HealthCheck`'s, taken by the window, never by this view.
struct SettingsHealthPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var health: HealthCheck

    var body: some View {
        let facts = health.facts(model)
        let checks = HealthWords.checks(HealthReport.checks(for: facts))
        let readings = HealthWords.readings(HealthReport.readings(for: facts))
        SettingsPage {
            SettingsGroup(title: L("Health"), warnings: checks.warnings) {
                ForEach(checks) { row in
                    StatusRow(row.label, mark: StatusMark(StatusSeverity(row.level), row.word)).help(row.detail ?? "")
                }
                ButtonRow {
                    if health.isChecking { ProgressView().controlSize(.small) }
                    Button(L("Check Again")) { health.checkAgain(model) }
                        .disabled(health.isChecking)
                }
            }
            SettingsGroup(title: L("Information")) {
                ForEach(readings) { row in
                    StatusRow(row.label, mark: .info(row.value)).help(row.detail ?? "")
                }
            }
        }
    }
}
