import SwiftUI

/// Generic view model that binds a Feature to SwiftUI.
///
/// Owns the state and constructs the feature internally. Views get
/// **read-only** access through dynamic member lookup (`viewModel.items`)
/// — the writable `Mutable` is internal to the handle path, so
/// unidirectionality is enforced by the type system, not convention.
/// Two-way controls go through `binding(_:send:)`, which routes writes
/// back as actions.
///
/// Observation lives in `Mutable` (granular, per top-level State field);
/// ViewModel just forwards reads through it.
@MainActor
@dynamicMemberLookup
public final class ViewModel<F: Feature> {
    /// The writable state — the handle path's API, not the view's.
    let state: Mutable<F.State>
    private let _handle: @MainActor (F.Action) async -> Void
    private var children: [ScopeKey: AnyObject] = [:]

    public convenience init(state: F.State, dependencies: F.Dependencies) {
        self.init(state: Mutable(state), dependencies: dependencies)
    }

    /// Used by `scope` to run a child feature over a lens.
    init(state: Mutable<F.State>, dependencies: F.Dependencies) {
        let feature = F()
        self.state = state
        let s = state
        self._handle = { action in
            await feature.handle(state: s, action: action, dependencies: dependencies)
        }
    }

    init(state: Mutable<F.State>, handle: @escaping @MainActor (F.Action) async -> Void) {
        self.state = state
        self._handle = handle
    }

    public func send(_ action: F.Action) {
        let handle = self._handle
        Task {
            await handle(action)
        }
    }

    // MARK: - View access (read-only)

    /// Read-only projection of state. `KeyPath`, not `WritableKeyPath` —
    /// `viewModel.count = 5` does not compile from a view.
    public subscript<T>(dynamicMember keyPath: KeyPath<F.State, T>) -> T {
        state[dynamicMember: keyPath]
    }

    /// Bridges a SwiftUI control to the action flow: reads from state,
    /// writes by sending an action.
    public func binding<T>(
        _ keyPath: KeyPath<F.State, T>,
        send action: @escaping (T) -> F.Action
    ) -> Binding<T> {
        Binding(
            get: { self[dynamicMember: keyPath] },
            set: { self.send(action($0)) }
        )
    }
}

// MARK: - Convenience for dependency-free features

extension ViewModel where F.Dependencies == Never {
    public convenience init(state: F.State) {
        let feature = F()
        let s = Mutable(state)
        self.init(state: s, handle: { action in
            await feature.handle(state: s, action: action)
        })
    }
}

// MARK: - Scoping

extension ViewModel {
    /// Returns a child ViewModel running `Child` over a slice of this
    /// feature's state. Memoized by key path + child type: the same
    /// instance is returned on every call, so it is safe to call in `body`.
    ///
    /// Note: `dependencies` is captured on the **first** call only. If the
    /// child's dependencies include a delegate closure back to this
    /// ViewModel, capture it weakly (`[weak viewModel]`) to avoid a
    /// parent → child → parent retain cycle.
    public func scope<Child: Feature>(
        _ child: Child.Type,
        state keyPath: WritableKeyPath<F.State, Child.State>,
        dependencies: Child.Dependencies
    ) -> ViewModel<Child> {
        let key = ScopeKey(keyPath: keyPath, childType: ObjectIdentifier(Child.self))
        if let cached = children[key] as? ViewModel<Child> { return cached }
        let childViewModel = ViewModel<Child>(
            state: state.scope(keyPath),
            dependencies: dependencies
        )
        children[key] = childViewModel
        return childViewModel
    }

    /// Scopes to a dependency-free child feature.
    public func scope<Child: Feature>(
        _ child: Child.Type,
        state keyPath: WritableKeyPath<F.State, Child.State>
    ) -> ViewModel<Child> where Child.Dependencies == Never {
        let key = ScopeKey(keyPath: keyPath, childType: ObjectIdentifier(Child.self))
        if let cached = children[key] as? ViewModel<Child> { return cached }
        let feature = Child()
        let s = state.scope(keyPath)
        let childViewModel = ViewModel<Child>(state: s, handle: { action in
            await feature.handle(state: s, action: action)
        })
        children[key] = childViewModel
        return childViewModel
    }
}

private struct ScopeKey: Hashable {
    let keyPath: AnyKeyPath
    let childType: ObjectIdentifier
}
