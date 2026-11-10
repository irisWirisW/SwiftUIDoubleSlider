import AppKit
import SwiftUI

/// A horizontal range slider backed by a single native AppKit slider.
///
/// On macOS 26 and later, supported AppKit runtimes provide native Liquid Glass
/// through private visual providers. Other runtimes use native cell drawing.
/// External values are constrained for display; bindings are written only in
/// response to user input. A zero step permits continuous values.
@MainActor
public struct DoubleSlider: View {
    @Binding private var lowerValue: Double
    @Binding private var upperValue: Double

    private let bounds: ClosedRange<Double>
    private let step: Double
    private let minimumDistance: Double
    private let tint: Color?

    /// Creates a slider for two endpoints within `bounds`.
    ///
    /// `minimumDistance` prevents the endpoints from approaching more closely
    /// than the specified distance. `tint` defaults to the system accent color.
    public init(
        lowerValue: Binding<Double>,
        upperValue: Binding<Double>,
        in bounds: ClosedRange<Double> = 0...100,
        step: Double = 0,
        minimumDistance: Double = 0,
        tint: Color? = nil
    ) {
        _lowerValue = lowerValue
        _upperValue = upperValue
        self.bounds = bounds
        self.step = step
        self.minimumDistance = minimumDistance
        self.tint = tint
    }

    public var body: some View {
        SliderRepresentable(lowerValue: $lowerValue, upperValue: $upperValue,
                            bounds: bounds, step: step, minimumDistance: minimumDistance, tint: tint)
    }
}

@MainActor
private struct SliderRepresentable: NSViewRepresentable {
    @Binding var lowerValue: Double
    @Binding var upperValue: Double
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let bounds: ClosedRange<Double>
    let step: Double
    let minimumDistance: Double
    let tint: Color?

    func makeCoordinator() -> Coordinator {
        Coordinator(lowerValue: $lowerValue, upperValue: $upperValue)
    }

    func makeNSView(context: Context) -> NativeDoubleSlider {
        let slider = NativeDoubleSlider(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.onValueChanged = { [weak coordinator = context.coordinator] slider in
            coordinator?.valueChanged(slider)
        }
        return slider
    }

    func updateNSView(_ slider: NativeDoubleSlider, context: Context) {
        context.coordinator.lowerValue = $lowerValue
        context.coordinator.upperValue = $upperValue
        slider.configure(bounds: bounds, step: step, minimumDistance: minimumDistance)
        slider.setValues(lower: lowerValue, upper: upperValue)
        if slider.isEnabled != isEnabled { slider.isEnabled = isEnabled }
        let size: NSControl.ControlSize
        switch controlSize {
        case .mini: size = .mini
        case .small: size = .small
        case .large: size = .large
        default: size = .regular
        }
        if slider.controlSize != size { slider.controlSize = size }
        let color: NSColor
        if let tint {
            if #available(macOS 14.0, *) {
                let resolved = tint.resolve(in: context.environment)
                color = NSColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green),
                                blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
            } else {
                color = NSColor(tint)
            }
        } else {
            color = .controlAccentColor
        }
        if slider.accentColor != color { slider.accentColor = color }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeDoubleSlider, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 280
        return CGSize(width: width, height: 44)
    }

    static func dismantleNSView(_ slider: NativeDoubleSlider, coordinator: Coordinator) {
        slider.onValueChanged = nil
        slider.isEnabled = false
    }

    @MainActor
    final class Coordinator {
        fileprivate var lowerValue: Binding<Double>
        fileprivate var upperValue: Binding<Double>

        fileprivate init(lowerValue: Binding<Double>, upperValue: Binding<Double>) {
            self.lowerValue = lowerValue
            self.upperValue = upperValue
        }

        fileprivate func valueChanged(_ slider: NativeDoubleSlider) {
            let lower = slider.lowerValue
            let upper = slider.upperValue
            if lowerValue.wrappedValue != lower { lowerValue.wrappedValue = lower }
            if upperValue.wrappedValue != upper { upperValue.wrappedValue = upper }
        }
    }
}
