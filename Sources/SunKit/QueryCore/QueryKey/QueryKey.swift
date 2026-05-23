/// A typed cache identity for a query result.
///
/// `QueryKey` is the public key type used by query APIs. The generic `Value`
/// identifies the data type expected for the key, while `rawValue` keeps the
/// type-erased parts needed for prefix invalidation.
public struct QueryKey<Value: Sendable>: Hashable, Sendable {
    /// The type-erased representation used for cache storage and matching.
    public let rawValue: AnyQueryKey

    /// Creates a query key from individual key parts.
    ///
    /// Key part equality includes both the part value and the part's concrete
    /// type, so `"1"` and `1` are different key parts.
    public init<each Part: Hashable & Sendable>(_ parts: repeat each Part) {
        var erasedParts: [AnyQueryKeyPart] = []
        for part in repeat each parts {
            erasedParts.append(AnyQueryKeyPart(part))
        }
        self.rawValue = AnyQueryKey(erasedParts)
    }

    /// Creates a query key from type-erased key parts.
    public init(_ parts: [AnyQueryKeyPart]) {
        self.rawValue = AnyQueryKey(parts)
    }
}

/// A type-erased query key used for cache matching and invalidation.
public struct AnyQueryKey: Hashable, Sendable {
    /// The ordered parts that make up this key.
    public let parts: [AnyQueryKeyPart]

    /// Creates a key from individual key parts.
    ///
    /// Prefix invalidation compares these parts in order.
    public init<each Part: Hashable & Sendable>(_ parts: repeat each Part) {
        var erasedParts: [AnyQueryKeyPart] = []
        for part in repeat each parts {
            erasedParts.append(AnyQueryKeyPart(part))
        }
        self.parts = erasedParts
    }

    /// Creates a key from type-erased key parts.
    public init(_ parts: [AnyQueryKeyPart]) {
        self.parts = parts
    }

    /// Returns whether this key starts with `prefix`.
    ///
    /// This supports prefix invalidation. For example, `["projects", 1]`
    /// starts with `["projects"]`, but not with `["project"]`.
    public func starts(with prefix: AnyQueryKey) -> Bool {
        guard prefix.parts.count <= parts.count else {
            return false
        }

        return zip(parts, prefix.parts).allSatisfy(==)
    }
}

/// A type-erased, hashable query key part.
///
/// Equality and hashing include both the wrapped value and its concrete type.
/// This keeps values such as `"1"` and `1` distinct in cache keys.
public struct AnyQueryKeyPart: Hashable, Sendable {
    private let box: any QueryKeyPartBox

    /// Creates a key part from any hashable and sendable value.
    public init<Part: Hashable & Sendable>(_ value: Part) {
        self.box = ConcreteQueryKeyPartBox(value)
    }

    public static func == (lhs: AnyQueryKeyPart, rhs: AnyQueryKeyPart) -> Bool {
        lhs.box.equals(rhs.box)
    }

    public func hash(into hasher: inout Hasher) {
        box.hash(into: &hasher)
    }
}

extension AnyQueryKeyPart: ExpressibleByStringLiteral {
    public typealias StringLiteralType = String

    /// Creates a key part from a string literal.
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension AnyQueryKeyPart: ExpressibleByIntegerLiteral {
    public typealias IntegerLiteralType = Int

    /// Creates a key part from an integer literal.
    public init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension AnyQueryKeyPart: ExpressibleByFloatLiteral {
    public typealias FloatLiteralType = Double

    /// Creates a key part from a floating-point literal.
    public init(floatLiteral value: Double) {
        self.init(value)
    }
}

extension AnyQueryKeyPart: ExpressibleByBooleanLiteral {
    public typealias BooleanLiteralType = Bool

    /// Creates a key part from a Boolean literal.
    public init(booleanLiteral value: Bool) {
        self.init(value)
    }
}

private protocol QueryKeyPartBox: Sendable {
    func equals(_ other: any QueryKeyPartBox) -> Bool
    func hash(into hasher: inout Hasher)
}

private struct ConcreteQueryKeyPartBox<Value: Hashable & Sendable>: QueryKeyPartBox {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    func equals(_ other: any QueryKeyPartBox) -> Bool {
        guard let other = other as? Self else {
            return false
        }

        return value == other.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(Value.self))
        hasher.combine(value)
    }
}
