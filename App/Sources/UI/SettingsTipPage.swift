import AppKit
import SwiftUI
import KoffeeLidCore

/// What the app costs, and the one way to say thank you: the app icon beside the sentence that says every
/// feature is free and stays free, then the one offer, which opens the Ko-fi page in the browser.
///
/// The two cards here hold pictures and sentences rather than controls, which no other page does. The owner
/// asked for that look; the rule it departs from is written beside `SettingsGroup`.
struct SettingsTipPage: View {
    var body: some View {
        SettingsPage {
            // No title: the sentence is the whole of it, and a heading above it would only repeat the
            // page's own.
            SettingsGroup {
                TipIntroRow()
            }
            SettingsGroup(title: L("One-time tip"),
                          hint: String(format: L("Ko-fi opens in your browser. €%d is the smallest tip, and you can type any amount there."),
                                       SupportLink.smallestTip)) {
                TipOfferRow()
            }
        }
    }
}

/// The app's own icon, small, and the sentence beside it.
private struct TipIntroRow: View {
    var body: some View {
        SettingsRowFrame {
            HStack(alignment: .center, spacing: SettingsMetrics.tipPictureGap) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: SettingsMetrics.tipAppIconSide, height: SettingsMetrics.tipAppIconSide)
                Text(L("KoffeeLid offers all its features free to everyone, and always will. You can support this project by offering me a coffee."))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The one offer: the Ko-fi cup in a tile of its own colour, what the tip is, and the button that opens
/// the page. The button is `.bordered` and not `.borderedProminent`: an update is the window's one
/// prominent action.
private struct TipOfferRow: View {
    var body: some View {
        // Its own padding, equal on every side, rather than `SettingsRowFrame`'s: that frame is fitted
        // to a text row and pinches the 88 pt tile top and bottom.
        HStack(alignment: .top, spacing: SettingsMetrics.tipPictureGap) {
            KoFiMark()
                .fill(KoFiMark.red)
                .frame(width: SettingsMetrics.tipMarkSide, height: SettingsMetrics.tipMarkSide)
                .frame(width: SettingsMetrics.tipTileSide, height: SettingsMetrics.tipTileSide)
                .background(
                    RoundedRectangle(cornerRadius: SettingsMetrics.tipTileRadius)
                        .fill(KoFiMark.red.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                Text(L("A cup of coffee"))
                    .font(.body)
                Text(L("A good coffee to keep this project going"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(format: L("Tip €%d"), SupportLink.smallestTip)) {
                    NSWorkspace.shared.open(SupportLink.koFi)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .padding(.top, SettingsMetrics.rowSpacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SettingsMetrics.tipOfferPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
