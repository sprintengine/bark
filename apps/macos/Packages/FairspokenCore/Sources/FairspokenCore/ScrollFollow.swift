import CoreGraphics

/// Keeps a growing text view pinned to its newest line until the person scrolls up, and pins
/// it again once they scroll back to the bottom.
///
/// Feed it every scroll-geometry change. A change in the content or viewport height is the
/// text growing (or the view resizing): while following, the view should jump to the bottom.
/// A change in offset alone is the person scrolling: following then means "at the bottom".
public struct ScrollFollow: Equatable, Sendable {
    /// How close to the bottom (points) still counts as at the bottom.
    public static let tolerance: CGFloat = 6

    public private(set) var following = true
    private var lastContentHeight: CGFloat?
    private var lastViewportHeight: CGFloat?

    public init() {}

    public static func isAtBottom(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        offset >= contentHeight - viewportHeight - tolerance
    }

    /// Is there text above the visible part (for the fade at the top)?
    public static func hasMoreAbove(offset: CGFloat) -> Bool {
        offset > 4
    }

    /// Records a geometry change; true when the view should scroll to the bottom now.
    public mutating func update(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        let atBottom = Self.isAtBottom(offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight)
        let resized = contentHeight != lastContentHeight || viewportHeight != lastViewportHeight
        lastContentHeight = contentHeight
        lastViewportHeight = viewportHeight
        if resized {
            // Text shrinking (a re-decode) can land a scrolled-up view at the bottom.
            if atBottom { following = true }
            return following && !atBottom
        }
        following = atBottom
        return false
    }

    /// A new dictation starts at the bottom.
    public mutating func reset() { self = ScrollFollow() }
}
