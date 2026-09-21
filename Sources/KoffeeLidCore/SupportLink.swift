import Foundation

/// Where a tip goes. One page for every app of this author, opened from Settings › Tip.
public enum SupportLink {
    public static let koFi = URL(string: "https://ko-fi.com/bambidotexe")!
    /// The smallest tip the Ko-fi page takes, which is also the amount it offers first. The button names
    /// it so the price is known before the browser opens; anything larger is typed on the page itself.
    public static let smallestTip = 5
}
