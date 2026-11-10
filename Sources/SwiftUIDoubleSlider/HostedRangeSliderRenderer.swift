import AppKit
import ObjectiveC.runtime
import QuartzCore

/// Adds a second native slider cell and visual provider to one NSSlider.
/// Private selectors and the hosted layer hierarchy are isolated in this file.
@MainActor
internal final class HostedRangeSliderRenderer {
    let lowerCell: NSSliderCell
    let upperCell: NSSliderCell

    private weak var container: NSSlider?
    private let lowerProvider: NSObject
    private let upperProvider: NSObject
    private let lowerModel: NSObject
    private let upperModel: NSObject
    private weak var lowerHost: NSView?
    private weak var upperHost: NSView?
    private let lowerTrack: HostedSliderTrackVisibility
    private let upperTrack: HostedSliderTrackVisibility
    private var activeHandle: SliderRange.Handle = .lower
    private var isLayingOut = false
    private var cachedLowerKnobRect = NSRect.zero
    private var lastLayoutBounds: NSRect?

    private static let providerSelector = NSSelectorFromString("_visualProvider")
    private static let setControlSelector = NSSelectorFromString("setControlView:")
    private static let layoutSelector = NSSelectorFromString("_layoutComponentSubviewsIfNecessary")
    private static let drawingSelector = NSSelectorFromString("_updateComponentSubviewDrawingStateIfNecessary")
    private static let pressedSelector = NSSelectorFromString("setIsPressed:")
    private static let neutralSelector = NSSelectorFromString("setNeutralValue:")
    private static let fillSelector = NSSelectorFromString("setTrackFillColor:")

    init?(container: NSView) {
        guard #available(macOS 26.0, *),
              let slider = container as? NSSlider,
              let primary = slider.cell as? NSSliderCell else { return nil }
        // The primary is the actual control's ordinary NSSliderCell. Assigning
        // its value materializes the lazy native model without creating a view.
        primary.doubleValue = primary.doubleValue
        let secondary = NSSliderCell()
        secondary.minValue = primary.minValue
        secondary.maxValue = primary.maxValue
        secondary.doubleValue = 25
        secondary.isVertical = false
        secondary.sliderType = .linear
        guard let firstModel = Self.sliderModel(of: primary),
              let secondModel = Self.sliderModel(of: secondary),
              Self.supports(firstModel, Self.pressedSelector, result: "v", argument: "B"),
              Self.supports(secondModel, Self.pressedSelector, result: "v", argument: "B"),
              Self.supports(primary, Self.neutralSelector, result: "v", argument: "d"),
              Self.supports(secondary, Self.neutralSelector, result: "v", argument: "d"),
              Self.supports(primary, Self.fillSelector, result: "v", argument: "@"),
              Self.supports(secondary, Self.fillSelector, result: "v", argument: "@"),
              let firstProvider = Self.provider(for: primary) else { return nil }

        // Attach and lay out the existing provider before taking the subview
        // snapshot used to identify the second provider's new hosting view.
        Self.setObject(slider, on: firstProvider, selector: Self.setControlSelector)
        primary.calcDrawInfo(slider.bounds)
        Self.updateProvider(firstProvider)
        guard let firstHost = Self.hosts(in: slider).first else { return nil }
        let originalHosts = Set(Self.hosts(in: slider).map(ObjectIdentifier.init))
        secondary.controlView = slider
        guard let secondProvider = Self.provider(for: secondary), secondProvider !== firstProvider else {
            secondary.controlView = nil
            return nil
        }
        Self.setObject(slider, on: secondProvider, selector: Self.setControlSelector)
        secondary.calcDrawInfo(slider.bounds)
        Self.updateProvider(secondProvider)
        guard let secondHost = Self.hosts(in: slider).first(where: {
            !originalHosts.contains(ObjectIdentifier($0))
        }) else {
            Self.setObject(nil, on: secondProvider, selector: Self.setControlSelector)
            secondary.controlView = nil
            return nil
        }

        self.container = slider
        upperCell = primary
        lowerCell = secondary
        upperProvider = firstProvider
        lowerProvider = secondProvider
        upperModel = firstModel
        lowerModel = secondModel
        upperHost = firstHost
        lowerHost = secondHost
        lowerTrack = HostedSliderTrackVisibility(container: slider, cell: secondary, hidesTracks: true)
        upperTrack = HostedSliderTrackVisibility(container: slider, cell: primary, hidesTracks: false)
        bindHosts()
    }

    func update(
        bounds: ClosedRange<Double>, lower: Double, upper: Double,
        enabled: Bool, accent: NSColor, controlSize: NSControl.ControlSize,
        active: SliderRange.Handle, pressed: Bool, focused: Bool
    ) {
        activeHandle = active
        if let slider = container as? NativeDoubleSlider { cachedLowerKnobRect = slider.handleRect(for: .lower) }
        for cell in [lowerCell, upperCell] {
            cell.minValue = bounds.lowerBound
            cell.maxValue = bounds.upperBound
            cell.isEnabled = enabled
            cell.controlSize = controlSize
            Self.setDouble(lower, on: cell, selector: Self.neutralSelector)
            Self.setObject(accent, on: cell, selector: Self.fillSelector)
        }
        upperCell.doubleValue = upper
        lowerCell.doubleValue = lower
        lowerCell.showsFirstResponder = focused && active == .lower
        upperCell.showsFirstResponder = focused && active == .upper
        Self.setBoolean(enabled && pressed && active == .lower, on: lowerModel, selector: Self.pressedSelector)
        Self.setBoolean(enabled && pressed && active == .upper, on: upperModel, selector: Self.pressedSelector)
        if let container { layout(in: container.bounds) }
    }

    func layout(in bounds: NSRect) {
        guard let container, !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        if lastLayoutBounds != bounds {
            lastLayoutBounds = bounds
            if let slider = container as? NativeDoubleSlider { cachedLowerKnobRect = slider.handleRect(for: .lower) }
        }
        updateHost(for: upperProvider, cell: upperCell, isLower: false, bounds: bounds, in: container)
        updateHost(for: lowerProvider, cell: lowerCell, isLower: true, bounds: bounds, in: container)
        bindHosts()
    }

    func cancelPress() {
        Self.setBoolean(false, on: lowerModel, selector: Self.pressedSelector)
        Self.setBoolean(false, on: upperModel, selector: Self.pressedSelector)
        lowerTrack.refresh()
        upperTrack.refresh()
    }

    private func updateHost(for provider: NSObject, cell: NSSliderCell, isLower: Bool,
                            bounds: NSRect, in container: NSSlider) {
        let before = Set(Self.hosts(in: container).map(ObjectIdentifier.init))
        cell.calcDrawInfo(bounds)
        Self.updateProvider(provider)
        let current = isLower ? lowerHost : upperHost
        if current?.superview !== container {
            let other = isLower ? upperHost : lowerHost
            let candidates = Self.hosts(in: container).filter { $0 !== other }
            let host = candidates.first { !before.contains(ObjectIdentifier($0)) } ?? candidates.first
            if isLower { lowerHost = host } else { upperHost = host }
        }
    }

    private func bindHosts() {
        for host in [upperHost, lowerHost].compactMap({ $0 }) {
            host.setAccessibilityElement(false)
            host.setAccessibilityHidden(true)
        }
        // The active thumb stays in front, including throughout release. When
        // the primary host is on top, its track must avoid the lower thumb.
        if let container, let upperHost, let lowerHost {
            let front = activeHandle == .lower ? lowerHost : upperHost
            let back = activeHandle == .lower ? upperHost : lowerHost
            if (container.subviews.firstIndex(of: front) ?? 0) < (container.subviews.firstIndex(of: back) ?? 0) {
                container.addSubview(front, positioned: .above, relativeTo: back)
            }
        }
        lowerTrack.host = lowerHost
        upperTrack.host = upperHost
        // Querying cell metrics changes its value temporarily and may invalidate
        // AppKit layout. KVO callbacks must only read geometry cached above.
        upperTrack.excludedKnobRect = activeHandle == .upper ? cachedLowerKnobRect : nil
        lowerTrack.refresh()
        upperTrack.refresh()
    }

    private static func hosts(in view: NSView) -> [NSView] {
        view.subviews.filter { NSStringFromClass(type(of: $0)).contains("_NSCoreHostingView") }
    }

    private static func provider(for cell: NSSliderCell) -> NSObject? {
        guard supports(cell, providerSelector, result: "@"),
              let provider = cell.perform(providerSelector)?.takeUnretainedValue() as? NSObject,
              supports(provider, setControlSelector, result: "v", argument: "@"),
              supports(provider, layoutSelector, result: "v"),
              supports(provider, drawingSelector, result: "v") else { return nil }
        return provider
    }

    private static func updateProvider(_ provider: NSObject) {
        provider.perform(layoutSelector)
        provider.perform(drawingSelector)
    }

    private static func sliderModel(of cell: NSSliderCell) -> NSObject? {
        guard let ivar = class_getInstanceVariable(type(of: cell), "_sliderModel"),
              let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 64 else { return nil }
        return object_getIvar(cell, ivar) as? NSObject
    }

    private static func supports(_ object: NSObject, _ selector: Selector,
                                 result: String, argument: String? = nil) -> Bool {
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == (argument == nil ? 2 : 3) else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == result else { return false }
        guard let argument else { return true }
        guard let argumentType = method_copyArgumentType(method, 2) else { return false }
        defer { free(argumentType) }
        let encoding = String(cString: argumentType)
        return encoding == argument || (argument == "B" && encoding == "c")
    }

    private static func setBoolean(_ value: Bool, on object: NSObject, selector: Selector) {
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
    }

    private static func setDouble(_ value: Double, on object: NSObject, selector: Selector) {
        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
    }

    private static func setObject(_ value: AnyObject?, on object: NSObject, selector: Selector) {
        object.perform(selector, with: value)
    }
}

/// Hides the secondary track and clips the primary track around a thumb behind
/// it. Both live glass subtrees remain owned and animated entirely by AppKit.
@MainActor
private final class HostedSliderTrackVisibility {
    weak var host: NSView?
    var excludedKnobRect: NSRect?
    private weak var container: NSView?
    private weak var cell: NSSliderCell?
    private let hidesTracks: Bool
    private var masks: [ObjectIdentifier: CAShapeLayer] = [:]
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var isRefreshing = false
    private var refreshAgain = false
    private var scheduledRefresh = false

    init(container: NSView, cell: NSSliderCell, hidesTracks: Bool) {
        self.container = container
        self.cell = cell
        self.hidesTracks = hidesTracks
    }

    func refresh() {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            rebuildObservationsAndAdjustTracks()
        } while refreshAgain
    }

    private func changed() {
        refresh()
        guard !scheduledRefresh else { return }
        scheduledRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduledRefresh = false
            self.refresh()
        }
    }

    private nonisolated func observedLayerChange() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { changed() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.changed() }
        }
    }

    private func rebuildObservationsAndAdjustTracks() {
        guard let container, let host, let cell else {
            observations.removeAll()
            masks.removeAll()
            return
        }
        var layers: [CALayer] = []
        var tracks: [CALayer] = []
        let bar = cell.barRect(flipped: container.isFlipped)
        if let hostLayer = host.layer {
            layers.append(hostLayer)
            for group in hostLayer.sublayers ?? [] {
                layers.append(group)
                for part in group.sublayers ?? [] {
                    layers.append(part)
                    let rect = part.convert(part.bounds, to: container.layer)
                    if bar.height > 0,
                       abs(rect.height - bar.height) <= 0.5,
                       abs(rect.midY - bar.midY) <= 0.5 {
                        tracks.append(part)
                    }
                }
            }
        }
        let current = Set(layers.map(ObjectIdentifier.init))
        for key in observations.keys where !current.contains(key) { observations.removeValue(forKey: key) }
        for layer in layers where observations[ObjectIdentifier(layer)] == nil {
            observations[ObjectIdentifier(layer)] = [
                layer.observe(\.sublayers, options: []) { [weak self] _, _ in self?.observedLayerChange() },
                layer.observe(\.bounds, options: []) { [weak self] _, _ in self?.observedLayerChange() },
                layer.observe(\.position, options: []) { [weak self] _, _ in self?.observedLayerChange() },
                layer.observe(\.isHidden, options: []) { [weak self] _, _ in self?.observedLayerChange() }
            ]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let trackIDs = Set(tracks.map(ObjectIdentifier.init))
        for key in masks.keys where !trackIDs.contains(key) { masks.removeValue(forKey: key) }
        let excludedRect = excludedKnobRect
        for track in tracks {
            if hidesTracks {
                if !track.isHidden { track.isHidden = true }
                continue
            }
            let key = ObjectIdentifier(track)
            if let excludedRect {
                let mask = masks[key] ?? CAShapeLayer()
                masks[key] = mask
                let knob = track.convert(excludedRect, from: container.layer)
                let path = CGMutablePath()
                path.addRect(track.bounds)
                path.addRoundedRect(in: knob, cornerWidth: knob.height / 2, cornerHeight: knob.height / 2)
                if mask.frame != track.bounds { mask.frame = track.bounds }
                if mask.bounds != track.bounds { mask.bounds = track.bounds }
                if mask.fillRule != .evenOdd { mask.fillRule = .evenOdd }
                if mask.path != path { mask.path = path }
                if track.mask !== mask { track.mask = mask }
            } else if let mask = masks.removeValue(forKey: key), track.mask === mask {
                track.mask = nil
            }
        }
        CATransaction.commit()
    }
}
