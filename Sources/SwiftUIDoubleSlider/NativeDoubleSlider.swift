import AppKit

/// A native range slider with two live system-hosted glass handles on modern AppKit.
/// Programmatic changes are silent; user changes send target/action and onValueChanged.
final class NativeDoubleSlider: NSSlider {
    private var selection = SliderRange()

    var valueRange: ClosedRange<Double> {
        get { selection.bounds }
        set { configure(bounds: newValue, step: step, minimumDistance: minimumDistance) }
    }

    var lowerValue: Double {
        get { selection.lowerValue }
        set { updateValue(newValue, for: .lower, notify: false) }
    }

    var upperValue: Double {
        get { selection.upperValue }
        set { updateValue(newValue, for: .upper, notify: false) }
    }

    /// Zero enables continuous values; positive values snap relative to the range start.
    var step: Double {
        get { selection.step }
        set { configure(bounds: valueRange, step: newValue, minimumDistance: minimumDistance) }
    }

    var minimumDistance: Double {
        get { selection.minimumDistance }
        set { configure(bounds: valueRange, step: step, minimumDistance: newValue) }
    }

    var accentColor: NSColor {
        get { trackFillColor ?? .controlAccentColor }
        set { trackFillColor = newValue }
    }

    override var trackFillColor: NSColor? {
        didSet { updateNativeCell() }
    }

    override var controlSize: NSControl.ControlSize {
        didSet { updateNativeCell() }
    }

    override var minValue: Double {
        get { valueRange.lowerBound }
        set {
            guard newValue.isFinite, newValue <= maxValue else { return }
            valueRange = newValue...maxValue
        }
    }

    override var maxValue: Double {
        get { valueRange.upperBound }
        set {
            guard newValue.isFinite, newValue >= minValue else { return }
            valueRange = minValue...newValue
        }
    }

    /// NSSlider's single-value API represents the upper endpoint.
    override var doubleValue: Double {
        get { upperValue }
        set { upperValue = newValue }
    }

    override var floatValue: Float {
        get { Float(upperValue) }
        set { upperValue = Double(newValue) }
    }

    override var intValue: Int32 {
        get { Int32(clamping: integerValue) }
        set { upperValue = Double(newValue) }
    }

    override var integerValue: Int {
        get {
            if upperValue >= Double(Int.max) { return Int.max }
            if upperValue <= Double(Int.min) { return Int.min }
            return Int(upperValue)
        }
        set { upperValue = Double(newValue) }
    }

    override var stringValue: String {
        get { String(upperValue) }
        set { if let value = Double(newValue) { upperValue = value } }
    }

    override var objectValue: Any? {
        get { NSNumber(value: upperValue) }
        set {
            if let number = newValue as? NSNumber { upperValue = number.doubleValue }
            else if let string = newValue as? String { stringValue = string }
        }
    }

    var onValueChanged: ((NativeDoubleSlider) -> Void)?
    private(set) var activeHandle: SliderRange.Handle = .lower {
        didSet {
            updateNativeCell()
            if oldValue != activeHandle, window?.firstResponder === self {
                NSAccessibility.post(element: accessibilityHandle(activeHandle), notification: .focusedUIElementChanged)
            }
        }
    }

    private var dragOffset: CGFloat = 0
    private var dragStartX: CGFloat = 0
    private var lastDragX: CGFloat?
    private var resolvesOverlappingHandles = false
    private var isDragging = false {
        didSet { updateNativeCell() }
    }
    private var changedDuringDrag = false
    private var nativeCell: NativeRangeSliderCell? { cell as? NativeRangeSliderCell }
    private let metricCell = NativeRangeSliderCell()
    private var hostedRenderer: HostedRangeSliderRenderer?
    private var windowResignedObserver: NSObjectProtocol?
    private lazy var lowerAccessibility = SliderAccessibilityHandle(owner: self, handle: .lower)
    private lazy var upperAccessibility = SliderAccessibilityHandle(owner: self, handle: .upper)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepare()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepare()
    }

    private func prepare() {
        // Use an ordinary NSSliderCell and its system hosting view. A second
        // cell/provider extends this same control with the lower endpoint.
        cell = NSSliderCell()
        (cell as? NSSliderCell)?.minValue = valueRange.lowerBound
        (cell as? NSSliderCell)?.maxValue = valueRange.upperBound
        cell?.doubleValue = upperValue
        sliderType = .linear
        isVertical = false
        isContinuous = true
        focusRingType = .default
        if #available(macOS 26.0, *) {
            hostedRenderer = HostedRangeSliderRenderer(container: self)
        }
        if hostedRenderer == nil { cell = NativeRangeSliderCell() }
        metricCell.controlView = self
        metricCell.rendersContent = false
        updateNativeCell()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("范围")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 44) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

    // Both native hosts belong to this one NSSlider. Range interaction and
    // accessibility stay here instead of the single-value system recognizers.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = windowResignedObserver { NotificationCenter.default.removeObserver(observer) }
        windowResignedObserver = nil
        cancelTracking()
        if let window {
            windowResignedObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.cancelTracking() }
        }
    }

    deinit {
        if let observer = windowResignedObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func cancelTracking() {
        isDragging = false
        changedDuringDrag = false
        hostedRenderer?.cancelPress()
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelTracking()
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            }
            updateNativeCell()
        }
    }

    /// Sets both endpoints atomically, sorting reversed inputs and applying constraints.
    func setValues(lower: Double, upper: Double) {
        if selection.setValues(lower: lower, upper: upper) { selectionDidChange() }
    }

    func configure(bounds: ClosedRange<Double>, step: Double, minimumDistance: Double) {
        if selection.configure(bounds: bounds, step: step, minimumDistance: minimumDistance) {
            selectionDidChange()
        }
    }

    @discardableResult
    private func updateValue(_ value: Double, for handle: SliderRange.Handle, notify: Bool) -> Bool {
        guard selection.setValue(value, for: handle) else { return false }
        selectionDidChange()
        if notify { sendValueChanged() }
        return true
    }

    private func selectionDidChange() {
        updateNativeCell()
        NSAccessibility.post(element: lowerAccessibility, notification: .valueChanged)
        NSAccessibility.post(element: upperAccessibility, notification: .valueChanged)
    }

    private func sendValueChanged() {
        if let action { sendAction(action, to: target) }
        onValueChanged?(self)
    }

    // MARK: Native cell rendering and geometry

    private func updateNativeCell() {
        guard let sliderCell = cell as? NSSliderCell else { return }
        sliderCell.minValue = valueRange.lowerBound
        sliderCell.maxValue = valueRange.upperBound
        sliderCell.doubleValue = upperValue
        sliderCell.showsFirstResponder = window?.firstResponder === self
        for candidate in [nativeCell, metricCell].compactMap({ $0 }) {
            candidate.minValue = valueRange.lowerBound
            candidate.maxValue = valueRange.upperBound
            candidate.doubleValue = upperValue
            candidate.lowerValue = lowerValue
            candidate.activeHandle = activeHandle
            candidate.isDraggingHandle = isDragging
            candidate.controlSize = controlSize
        }
        if #available(macOS 26.0, *) { neutralValue = lowerValue }
        hostedRenderer?.update(bounds: valueRange, lower: lowerValue, upper: upperValue,
                               enabled: isEnabled, accent: accentColor, controlSize: controlSize,
                               active: activeHandle, pressed: isDragging,
                               focused: window?.firstResponder === self)
        // AppKit otherwise installs tracking for its single upper value.
        // Our range event handlers own both endpoints, including overlap.
        for recognizer in gestureRecognizers { recognizer.isEnabled = false }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        nativeCell?.calcDrawInfo(bounds)
        metricCell.calcDrawInfo(bounds)
        hostedRenderer?.layout(in: bounds)
        for recognizer in gestureRecognizers { recognizer.isEnabled = false }
    }

    var renderingCells: [NSSliderCell] {
        if let renderer = hostedRenderer { return [renderer.lowerCell, renderer.upperCell] }
        return (cell as? NSSliderCell).map { [$0] } ?? []
    }

    var trackRect: NSRect {
        // The non-hosted cell can query both endpoint metrics synchronously.
        // A live hosting view caches its current animated knob position.
        let geometry = nativeCell ?? metricCell
        geometry.calcDrawInfo(bounds)
        let start = geometry.endpointKnobRect(isMaximum: false, flipped: isFlipped)
        let end = geometry.endpointKnobRect(isMaximum: true, flipped: isFlipped)
        return NSRect(x: start.midX, y: start.midY - 3, width: max(0, end.midX - start.midX), height: 6)
    }

    func handleRect(for handle: SliderRange.Handle) -> NSRect {
        // Input geometry follows the current model immediately. The live hosts
        // may still report a preceding frame while their release animation runs.
        let geometry = nativeCell ?? metricCell
        geometry.calcDrawInfo(bounds)
        return geometry.knobRect(for: handle, flipped: isFlipped)
    }

    private func value(atX x: CGFloat) -> Double {
        guard trackRect.width > 0 else { return valueRange.lowerBound }
        return selection.value(at: Double((x - trackRect.minX) / trackRect.width))
    }

    // MARK: Pointer interaction

    private func nearestHandle(to point: NSPoint) -> SliderRange.Handle {
        let lowerX = handleRect(for: .lower).midX
        let upperX = handleRect(for: .upper).midX
        if abs(point.x - lowerX) == abs(point.x - upperX) {
            if point.x < lowerX { return .lower }
            if point.x > upperX { return .upper }
            return activeHandle
        }
        return abs(point.x - lowerX) < abs(point.x - upperX) ? .lower : .upper
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, trackRect.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        activeHandle = nearestHandle(to: point)
        let rect = handleRect(for: activeHandle)
        let hitsHandle = rect.insetBy(dx: -4, dy: -4).contains(point)
        dragOffset = hitsHandle ? point.x - rect.midX : 0
        dragStartX = point.x
        lastDragX = hitsHandle ? point.x : nil
        resolvesOverlappingHandles = hitsHandle && lowerValue == upperValue
        isDragging = true
        changedDuringDrag = false
        if !hitsHandle { drag(to: point.x) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        if resolvesOverlappingHandles {
            guard abs(point.x - dragStartX) >= 1 else { return }
            activeHandle = point.x < dragStartX ? .lower : .upper
            resolvesOverlappingHandles = false
        }
        drag(to: point.x)
    }

    private func drag(to x: CGFloat) {
        // A click, or mouse-up at the last drag location, must not re-snap a
        // constraint-produced value that intentionally sits between steps.
        guard lastDragX != x else { return }
        lastDragX = x
        let changed = updateValue(value(atX: x - dragOffset), for: activeHandle, notify: isContinuous)
        changedDuringDrag = changedDuringDrag || changed
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        drag(to: convert(event.locationInWindow, from: nil).x)
        let shouldNotify = !isContinuous && changedDuringDrag
        isDragging = false
        changedDuringDrag = false
        needsDisplay = true
        if shouldNotify { sendValueChanged() }
    }

    // MARK: Keyboard interaction

    override func becomeFirstResponder() -> Bool {
        guard isEnabled else { return false }
        guard super.becomeFirstResponder() else { return false }
        activeHandle = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .upper : .lower
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        nativeCell?.showsFirstResponder = false
        if let renderer = hostedRenderer {
            renderer.update(bounds: valueRange, lower: lowerValue, upper: upperValue,
                            enabled: isEnabled, accent: accentColor, controlSize: controlSize,
                            active: activeHandle, pressed: isDragging, focused: false)
        }
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.keyCode {
        case 48: // Tab visits each handle before leaving the control.
            let backwards = event.modifierFlags.contains(.shift)
            if backwards && activeHandle == .upper { activeHandle = .lower }
            else if !backwards && activeHandle == .lower { activeHandle = .upper }
            else if backwards { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        case 123, 125:
            adjust(activeHandle, direction: -1, accelerated: event.modifierFlags.contains(.shift))
        case 124, 126:
            adjust(activeHandle, direction: 1, accelerated: event.modifierFlags.contains(.shift))
        case 115:
            updateValue(valueRange.lowerBound, for: activeHandle, notify: true)
        case 119:
            updateValue(valueRange.upperBound, for: activeHandle, notify: true)
        default:
            super.keyDown(with: event)
        }
    }

    @discardableResult
    fileprivate func adjust(_ handle: SliderRange.Handle, direction: Double, accelerated: Bool = false) -> Bool {
        guard isEnabled else { return false }
        activeHandle = handle
        let increment = step > 0 ? step : (valueRange.upperBound - valueRange.lowerBound) / 100
        let current = handle == .lower ? lowerValue : upperValue
        let proposed = current + direction * increment * (accelerated ? 10 : 1)
        // Huge, finite ranges may overflow during addition; still permit reaching the edge.
        let value = proposed.isFinite ? proposed : (direction > 0 ? valueRange.upperBound : valueRange.lowerBound)
        return updateValue(value, for: handle, notify: true)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { [lowerAccessibility, upperAccessibility] }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override var accessibilityFocusedUIElement: Any? {
        if window?.firstResponder === self { return accessibilityHandle(activeHandle) }
        return super.accessibilityFocusedUIElement
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return super.accessibilityHitTest(point) }
        let pointInWindow = window.convertPoint(fromScreen: point)
        let localPoint = convert(pointInWindow, from: nil)
        let handles: [SliderRange.Handle] = [activeHandle, activeHandle == .lower ? .upper : .lower]
        for handle in handles where handleRect(for: handle).insetBy(dx: -4, dy: -4).contains(localPoint) {
            return accessibilityHandle(handle)
        }
        return super.accessibilityHitTest(point)
    }

    private func accessibilityHandle(_ handle: SliderRange.Handle) -> SliderAccessibilityHandle {
        handle == .lower ? lowerAccessibility : upperAccessibility
    }

    fileprivate func focus(_ handle: SliderRange.Handle) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        activeHandle = handle
    }

    fileprivate func setAccessibleValue(_ value: Double, for handle: SliderRange.Handle) {
        guard isEnabled else { return }
        activeHandle = handle
        updateValue(value, for: handle, notify: true)
    }
}

/// Each endpoint is a separate VoiceOver slider, with its own constraints and actions.
private final class SliderAccessibilityHandle: NSAccessibilityElement {
    private weak var owner: NativeDoubleSlider?
    private let handle: SliderRange.Handle

    init(owner: NativeDoubleSlider, handle: SliderRange.Handle) {
        self.owner = owner
        self.handle = handle
        super.init()
        setAccessibilityRole(.slider)
        setAccessibilityLabel(handle == .lower ? "下限" : "上限")
    }

    override func accessibilityParent() -> Any? { owner }
    override func accessibilityValue() -> Any? {
        guard let owner else { return nil }
        return handle == .lower ? owner.lowerValue : owner.upperValue
    }
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let value = accessibilityValue as? NSNumber else { return }
        owner?.setAccessibleValue(value.doubleValue, for: handle)
    }
    override func accessibilityMinValue() -> Any? {
        guard let owner else { return nil }
        return handle == .lower ? owner.valueRange.lowerBound : owner.lowerValue + owner.minimumDistance
    }
    override func accessibilityMaxValue() -> Any? {
        guard let owner else { return nil }
        return handle == .lower ? owner.upperValue - owner.minimumDistance : owner.valueRange.upperBound
    }
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(owner.handleRect(for: handle), to: nil))
    }
    override func isAccessibilityEnabled() -> Bool { owner?.isEnabled ?? false }
    override func isAccessibilityFocused() -> Bool {
        guard let owner else { return false }
        return owner.window?.firstResponder === owner && owner.activeHandle == handle
    }
    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        if accessibilityFocused { owner?.focus(handle) }
    }
    override func accessibilityPerformIncrement() -> Bool { owner?.adjust(handle, direction: 1) ?? false }
    override func accessibilityPerformDecrement() -> Bool { owner?.adjust(handle, direction: -1) ?? false }
}
