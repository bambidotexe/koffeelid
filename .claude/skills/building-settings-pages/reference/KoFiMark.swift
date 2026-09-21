// The Ko-fi cup. Portable: SwiftUI only, nothing app-specific and nothing to edit. A NEW project copies
// this file, deletes this header, and draws the mark on its Tip page.

import SwiftUI

/// The Ko-fi cup: the mark Ko-fi publishes for a link to a Ko-fi page. One outline whose rim, handle and
/// heart are holes, filled with the nonzero rule, which is what `Shape` fills with.
///
/// A shape and not a picture file, so the mark is the same in every app of this author, stays sharp at any
/// size, and takes whatever colour it is filled with. `outline` is the published outline in its own
/// 24 × 24 box, with every arc already written as a curve: only moves and curves are read back.
struct KoFiMark: Shape {
    /// The side of the box `outline` is drawn in.
    private static let box: CGFloat = 24

    /// Ko-fi's own red, which the mark is drawn in wherever it stands for Ko-fi.
    static let red = Color(red: 1.0, green: 0.369, blue: 0.357)

    private static let outline =
        "M11.351 2.715 C8.651 2.715 6.365 2.74 4.521 2.975 C2.078 3.285 0 5.154 0 8.61" +
        " C0 12.116 0.182 14.74 1.585 17.103 C3.169 19.804 5.818 21.285 9.247 21.285" +
        " C9.247 21.285 10.077 21.285 10.077 21.285 C14.286 21.285 16.571 19.051 17.714 17.285" +
        " C18.1823 16.5589 18.5493 15.7723 18.805 14.947 C21.792 14.688 24 12.22 24 9.208" +
        " C24 9.208 24 8.793 24 8.793 C24 5.546 21.87 3.286 18.208 2.923" +
        " C16.65 2.767 15.558 2.715 11.351 2.715 M11.351 4.662 C15.559 4.662 16.441 4.714 17.922 4.844" +
        " C20.546 5.155 22.052 6.428 22.052 8.844 C22.052 8.844 22.052 9.234 22.052 9.234" +
        " C22.052 11.39 20.26 13.078 18.182 13.078 C18.182 13.078 17.247 13.078 17.247 13.078" +
        " C17.247 13.078 17.091 13.727 17.091 13.727 C16.883 14.74 16.494 15.545 16.052 16.273" +
        " C15.143 17.701 13.507 19.337 10.13 19.337 C10.13 19.337 9.325 19.337 9.325 19.337" +
        " C6.754 19.337 4.494 18.454 3.247 16.142 C2.157 14.142 1.949 11.987 1.949 8.636" +
        " C1.949 6.455 2.806 5.234 4.961 4.922 C6.494 4.689 8.52 4.662 11.351 4.662 M17.898 6.949" +
        " C17.482 6.949 17.248 7.183 17.248 7.495 C17.248 7.495 17.248 10.43 17.248 10.43" +
        " C17.248 10.741 17.482 10.975 17.898 10.975 C19.222 10.975 19.949 10.221 19.949 8.975" +
        " C19.949 7.729 19.222 6.949 17.897 6.949 M7.507 7.131 C5.689 7.131 4.494 8.611 4.494 10.273" +
        " C4.494 11.806 5.352 13.13 6.443 14.17 C7.17 14.871 8.313 15.599 9.092 16.066" +
        " C9.5561 16.3431 10.1349 16.3431 10.599 16.066 C11.379 15.599 12.521 14.871 13.222 14.17" +
        " C14.339 13.131 15.196 11.806 15.196 10.273 C15.196 8.611 13.949 7.131 12.157 7.131" +
        " C11.092 7.131 10.365 7.676 9.819 8.429 C9.326 7.676 8.573 7.131 7.507 7.131"

    /// The mark keeps its proportions and sits in the middle of whatever it is given.
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Self.box
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let scanner = Scanner(string: Self.outline)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        func next() -> CGPoint {
            CGPoint(x: (scanner.scanDouble() ?? 0) * scale + origin.x,
                    y: (scanner.scanDouble() ?? 0) * scale + origin.y)
        }
        var path = Path()
        while let command = scanner.scanCharacter() {
            switch command {
            case "M": path.move(to: next())
            case "C":
                let first = next(), second = next()
                path.addCurve(to: next(), control1: first, control2: second)
            default: break
            }
        }
        path.closeSubpath()
        return path
    }
}
