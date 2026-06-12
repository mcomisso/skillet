import SwiftUI

/// Owns all navigation state for a flow — stack, sheet, and full-screen cover.
/// Generic over a Route enum that defines all possible destinations in the flow.
@Observable
@MainActor
public final class Router<Route: Hashable> {
    public var path = NavigationPath()
    public var sheet: Route?
    public var fullScreenCover: Route?

    public init() {}

    // MARK: - Stack

    public func push(_ route: Route) {
        path.append(route)
    }

    public func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    public func popToRoot() {
        guard !path.isEmpty else { return }
        path.removeLast(path.count)
    }

    // MARK: - Sheet

    public func presentSheet(_ route: Route) {
        sheet = route
    }

    public func dismissSheet() {
        sheet = nil
    }

    // MARK: - Full-screen cover

    public func presentCover(_ route: Route) {
        fullScreenCover = route
    }

    public func dismissCover() {
        fullScreenCover = nil
    }
}
