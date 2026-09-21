// The Tip page, the same in every app of this author. Portable: AppKit + SwiftUI, nothing app-specific
// except the sentences marked EDIT and the Ko-fi address. A NEW project copies this file and
// KoFiMark.swift, deletes this header, translates the sentences, and adds a `tip` case to SettingsPageID
// with the symbol "mug".

import AppKit
import SwiftUI

/// Where the tip goes, and how much of it. One page for every app of this author.
enum SupportLink {
    /// EDIT: the author's Ko-fi page.
    static let koFi = URL(string: "https://ko-fi.com/bambidotexe")!
    /// The smallest tip the Ko-fi page takes, which is also the amount it offers first. The button names
    /// it so the price is known before the browser opens; anything larger is typed on the page itself.
    static let smallestTip = 5
}

/// What the app costs, and the one way to say thank you: the app icon beside the sentence that says every
/// feature is free and stays free, then the one offer, which opens the Ko-fi page in the browser.
///
/// The two cards here hold pictures and sentences rather than controls, which no other page does, and the
/// first has no title at all. The owner asked for that look; every other page keeps the rule that a row is
/// a control and its label and that nothing explanatory goes inside a card.
struct TipPage: View {
    var body: some View {
        SettingsPage {
            // No title: the sentence is the whole of it, and a heading above it would only repeat the
            // page's own.
            SettingsGroup {
                TipIntroRow()
            }
            SettingsGroup(title: "One-time tip",
                          // EDIT: every sentence on this page goes through the app's own string table.
                          hint: "Ko-fi opens in your browser. €\(SupportLink.smallestTip) is the smallest tip, and you can type any amount there.") {
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
                // EDIT: the app's own name.
                Text("AppName offers all its features free to everyone, and always will. You can support this project by offering me a coffee.")
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
        SettingsRowFrame {
            HStack(alignment: .top, spacing: SettingsMetrics.tipPictureGap) {
                KoFiMark()
                    .fill(KoFiMark.red)
                    .frame(width: SettingsMetrics.tipMarkSide, height: SettingsMetrics.tipMarkSide)
                    .frame(width: SettingsMetrics.tipTileSide, height: SettingsMetrics.tipTileSide)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius)
                            .fill(KoFiMark.red.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                    Text("A cup of coffee")
                        .font(.body)
                    Text("A good coffee to keep this project going")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Tip €\(SupportLink.smallestTip)") {
                        NSWorkspace.shared.open(SupportLink.koFi)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .padding(.top, SettingsMetrics.rowSpacing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
