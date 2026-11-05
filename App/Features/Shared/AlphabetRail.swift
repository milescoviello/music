import SwiftUI

/// The letter strip down the right edge, for lists too long to scroll.
///
/// 400 artists and 2,227 albums with no way to jump is a lot of flicking. SwiftUI has no
/// equivalent of `UITableView`'s index bar, so this is hand-built — but it only needs to
/// do one thing.
///
/// Letters absent from the list are dimmed rather than hidden, so the strip does not
/// reflow as the list loads and a tap never lands on a different letter than the one
/// under the finger.
struct AlphabetRail: View {
    /// Letters that actually have entries.
    let available: Set<String>
    let onSelect: (String) -> Void

    private static let letters =
        ["#"] + (65...90).map { String(UnicodeScalar($0)!) }

    /// Tracks the finger so dragging down the strip scrubs through letters, which is how
    /// the system control behaves and is most of why it feels quick.
    @State private var lastSent: String?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height / CGFloat(Self.letters.count)

            VStack(spacing: 0) {
                ForEach(Self.letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            available.contains(letter) ? Color.appTint : Color.secondary.opacity(0.35)
                        )
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Int(value.location.y / max(height, 1))
                        guard Self.letters.indices.contains(index) else { return }
                        let letter = Self.letters[index]
                        // Only on change, or a slow drag fires dozens of scrolls for one
                        // letter and the list stutters.
                        guard letter != lastSent, available.contains(letter) else { return }
                        lastSent = letter
                        onSelect(letter)
                    }
                    .onEnded { _ in lastSent = nil }
            )
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    /// The rail's bucket for a title: initial letter, or "#" for anything else, with
    /// leading articles ignored so "The Lanterns" files under L.
    static func bucket(for title: String) -> String {
        let stripped = Self.withoutLeadingArticle(title)
        guard let first = stripped.first?.uppercased() else { return "#" }
        return letters.contains(first) ? first : "#"
    }

    static func withoutLeadingArticle(_ title: String) -> String {
        let lower = title.lowercased()
        for article in ["the ", "a ", "an "] where lower.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }
}
