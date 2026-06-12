/// A stateless, Sendable logic container that processes actions
/// against externally-owned state.
///
/// Features hold no properties — they are pure logic units.
/// State is owned by ViewModel and passed into handle as Mutable<State>.
///
/// Dependencies defaults to Never. Dependency-free features implement
/// handle(state:action:). Features with dependencies add a typealias
/// and implement handle(state:action:dependencies:).
public protocol Feature: Sendable {
    associatedtype State: Sendable
    associatedtype Action: Sendable
    associatedtype Dependencies = Never

    init()

    @MainActor
    func handle(
        state: Mutable<State>,
        action: Action,
        dependencies: Dependencies
    ) async

    @MainActor
    func handle(
        state: Mutable<State>,
        action: Action
    ) async
}

// MARK: - Dependency-free features

extension Feature where Dependencies == Never {
    /// Witness only — `Never` can't be constructed, so this is uncallable.
    /// Dependency-free features are driven through `handle(state:action:)`
    /// via the `ViewModel(state:)` convenience initializer.
    @MainActor
    public func handle(
        state: Mutable<State>,
        action: Action,
        dependencies: Never
    ) async {}
}

// MARK: - Features with dependencies

extension Feature {
    /// Default no-op. Features with dependencies don't use this.
    @MainActor
    public func handle(
        state: Mutable<State>,
        action: Action
    ) async {}
}
