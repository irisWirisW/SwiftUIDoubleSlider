/// The value and constraint logic for a two-handle slider, independent of AppKit.
struct SliderRange {
    enum Handle: CaseIterable {
        case lower
        case upper
    }

    private(set) var bounds: ClosedRange<Double>
    private(set) var lowerValue: Double
    private(set) var upperValue: Double
    /// Zero means continuous values. Steps are measured from the lower bound.
    private(set) var step: Double
    private(set) var minimumDistance: Double

    /// Invalid domains fall back to 0...100. Nonfinite values use the domain endpoints.
    /// Negative or nonfinite step/distance values become zero.
    init(
        bounds: ClosedRange<Double> = 0...100,
        lowerValue: Double = 25,
        upperValue: Double = 75,
        step: Double = 0,
        minimumDistance: Double = 0
    ) {
        let validBounds = Self.isValid(bounds) ? bounds : 0...100
        self.bounds = validBounds
        self.lowerValue = validBounds.lowerBound
        self.upperValue = validBounds.upperBound
        self.step = Self.nonnegative(step)
        self.minimumDistance = min(Self.nonnegative(minimumDistance), Self.span(of: validBounds))
        normalizeValues(lower: lowerValue, upper: upperValue)
    }

    /// Moves one handle without moving the other. Returns whether a value changed.
    /// Constraints take priority over snapping: a minimum-distance boundary may be
    /// between steps. Both domain endpoints are always selectable.
    @discardableResult
    mutating func setValue(_ value: Double, for handle: Handle) -> Bool {
        guard value.isFinite else { return false }
        guard value != (handle == .lower ? lowerValue : upperValue) else { return false }
        let oldLower = lowerValue
        let oldUpper = upperValue
        let value = snapped(value)
        switch handle {
        case .lower:
            lowerValue = min(value, max(bounds.lowerBound, upperValue - minimumDistance))
        case .upper:
            upperValue = max(value, min(bounds.upperBound, lowerValue + minimumDistance))
        }
        return lowerValue != oldLower || upperValue != oldUpper
    }

    /// Updates both handles, sorting reversed inputs and ignoring nonfinite inputs.
    /// If the interval is too short, extends the upper handle first, then shifts
    /// the lower handle down if the upper bound prevents further expansion.
    @discardableResult
    mutating func setValues(lower: Double, upper: Double) -> Bool {
        // Reassigning a valid selection must not move off-grid endpoints that
        // were created by minimum-distance constraints or handle collisions.
        let proposedLower = lower.isFinite ? lower : lowerValue
        let proposedUpper = upper.isFinite ? upper : upperValue
        if min(proposedLower, proposedUpper) == lowerValue,
           max(proposedLower, proposedUpper) == upperValue {
            return false
        }
        return normalizeValues(lower: lower, upper: upper)
    }

    @discardableResult
    private mutating func normalizeValues(lower: Double, upper: Double) -> Bool {
        let oldLower = lowerValue
        let oldUpper = upperValue
        let first = lower.isFinite ? snapped(lower) : lowerValue
        let second = upper.isFinite ? snapped(upper) : upperValue
        lowerValue = min(first, second)
        upperValue = max(first, second)
        if upperValue - lowerValue < minimumDistance {
            upperValue = min(bounds.upperBound, lowerValue + minimumDistance)
            lowerValue = max(bounds.lowerBound, upperValue - minimumDistance)
        }
        return lowerValue != oldLower || upperValue != oldUpper
    }

    /// Reconfigures the domain and revalidates the selection. Returns whether any
    /// configuration or value changed. Invalid domains leave the entire state alone.
    /// Negative or nonfinite step/distance values become zero; distance is limited
    /// to the domain's length. The initializer uses the same normalization rules.
    @discardableResult
    mutating func configure(
        bounds: ClosedRange<Double>,
        step: Double,
        minimumDistance: Double
    ) -> Bool {
        guard Self.isValid(bounds) else { return false }
        let oldBounds = self.bounds
        let oldStep = self.step
        let oldDistance = self.minimumDistance
        self.bounds = bounds
        self.step = Self.nonnegative(step)
        self.minimumDistance = min(Self.nonnegative(minimumDistance), Self.span(of: bounds))
        guard oldBounds != bounds || oldStep != self.step || oldDistance != self.minimumDistance else {
            return false
        }
        let valuesChanged = normalizeValues(lower: lowerValue, upper: upperValue)
        return valuesChanged || oldBounds != bounds || oldStep != self.step
            || oldDistance != self.minimumDistance
    }

    /// Maps a value to 0...1 without applying step snapping. A point domain or a
    /// nonfinite input maps to zero, avoiding invalid drawing coordinates.
    func fraction(for value: Double) -> Double {
        let span = Self.span(of: bounds)
        guard value.isFinite, span > 0 else { return 0 }
        return (clamped(value) - bounds.lowerBound) / span
    }

    /// Maps a fraction to the domain without snapping. Out-of-range fractions
    /// clamp to endpoints; nonfinite fractions map to the lower endpoint.
    func value(at fraction: Double) -> Double {
        guard fraction.isFinite else { return bounds.lowerBound }
        if fraction <= 0 { return bounds.lowerBound }
        if fraction >= 1 { return bounds.upperBound }
        return clamped(bounds.lowerBound + Self.span(of: bounds) * fraction)
    }

    private func clamped(_ value: Double) -> Double {
        min(bounds.upperBound, max(bounds.lowerBound, value))
    }

    private func snapped(_ value: Double) -> Double {
        let value = clamped(value)
        guard step > 0, value > bounds.lowerBound, value < bounds.upperBound else {
            return value
        }
        let steps = (value - bounds.lowerBound) / step
        // Extremely small steps may overflow the quotient and are already below
        // representable precision here. Preserve the finite input in that case.
        guard steps.isFinite else { return value }
        let snappedValue = bounds.lowerBound + steps.rounded() * step
        return snappedValue.isFinite ? clamped(snappedValue) : value
    }

    private static func nonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func span(of bounds: ClosedRange<Double>) -> Double {
        bounds.upperBound - bounds.lowerBound
    }

    private static func isValid(_ bounds: ClosedRange<Double>) -> Bool {
        bounds.lowerBound.isFinite && bounds.upperBound.isFinite && span(of: bounds).isFinite
    }
}
