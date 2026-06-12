import Observation

/// Reference wrapper around a value type, enabling in-place mutation
/// of state through a class-based indirection.
///
/// **Granular observation.** A hand-rolled `ObservationRegistrar` (the
/// `@Observable` macro can only track whole properties) registers the
/// *appended* key path on every dynamic-member access, so a view reading
/// `state.items` is invalidated by writes to `items` — not by writes to
/// sibling fields. The re-render boundary is the **top-level field** of the
/// root State: design State layout by who renders each field.
///
/// **Lenses.** `scope(_:)` returns a write-through `Mutable` over a slice of
/// this state. A lens has no storage and no registrar — every access routes
/// through the parent, so all observation tracking lands in the root
/// registrar and granularity inside a slice is slice-level.
///
/// **Token scheme.** Three key-path classes keep invalidation precise:
/// - `\.value.<field>` — per-field observers, fired on that field's writes
/// - `\.value` — whole-value observers, fired on *any* write
/// - `\.replacedToken` — registered by field reads, fired on whole-value
///   replacement, so `state.value = ...` still reaches field observers
///
/// `@MainActor` so the compiler — not convention — guarantees all access
/// happens on the main actor. Globally isolated classes are implicitly
/// Sendable.
@MainActor
@dynamicMemberLookup
public final class Mutable<Value>: Observable {
    // Root storage — nil when this instance is a lens.
    private let registrar: ObservationRegistrar?
    private var storage: Value?

    // Lens routing — nil when this instance is the root.
    private let lensGet: (@MainActor () -> Value)?
    private let lensSet: (@MainActor (Value) -> Void)?

    // Fired (never read) on whole-value replacement; field reads register it.
    private var replacedToken = false

    /// Creates a root Mutable that owns its storage.
    public init(_ value: Value) {
        self.registrar = ObservationRegistrar()
        self.storage = value
        self.lensGet = nil
        self.lensSet = nil
    }

    /// Creates a lens routing through a parent.
    private init(
        get: @escaping @MainActor () -> Value,
        set: @escaping @MainActor (Value) -> Void
    ) {
        self.registrar = nil
        self.storage = nil
        self.lensGet = get
        self.lensSet = set
    }

    // MARK: - Whole-value access

    public var value: Value {
        get {
            if let lensGet { return lensGet() }
            registrar!.access(self, keyPath: \.value)
            return storage!
        }
        set {
            if let lensSet { lensSet(newValue); return }
            registrar!.willSet(self, keyPath: \.value)
            registrar!.willSet(self, keyPath: \.replacedToken)
            storage = newValue
            registrar!.didSet(self, keyPath: \.value)
            registrar!.didSet(self, keyPath: \.replacedToken)
        }
    }

    // MARK: - Field access

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> T {
        get {
            if let lensGet { return lensGet()[keyPath: keyPath] }
            registrar!.access(self, keyPath: (\Mutable<Value>.value).appending(path: keyPath))
            registrar!.access(self, keyPath: \.replacedToken)
            return storage![keyPath: keyPath]
        }
        set {
            if let lensGet, let lensSet {
                var slice = lensGet()
                slice[keyPath: keyPath] = newValue
                lensSet(slice)
                return
            }
            let fieldKeyPath = (\Mutable<Value>.value).appending(path: keyPath)
            registrar!.willSet(self, keyPath: fieldKeyPath)
            registrar!.willSet(self, keyPath: \.value)
            storage![keyPath: keyPath] = newValue
            registrar!.didSet(self, keyPath: fieldKeyPath)
            registrar!.didSet(self, keyPath: \.value)
        }
    }

    /// Read-only access — serves computed properties and `let` fields
    /// (e.g. derived values declared in State extensions).
    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        if let lensGet { return lensGet()[keyPath: keyPath] }
        registrar!.access(self, keyPath: (\Mutable<Value>.value).appending(path: keyPath))
        registrar!.access(self, keyPath: \.replacedToken)
        return storage![keyPath: keyPath]
    }

    // MARK: - Scoping

    /// Returns a write-through lens over a slice of this state.
    ///
    /// The lens keeps the parent alive and routes every read/write through
    /// it, so child mutations notify root observers of the slice and parent
    /// mutations are visible to the child immediately.
    public func scope<T>(_ keyPath: WritableKeyPath<Value, T>) -> Mutable<T> {
        Mutable<T>(
            get: { self[dynamicMember: keyPath] },
            set: { self[dynamicMember: keyPath] = $0 }
        )
    }
}
