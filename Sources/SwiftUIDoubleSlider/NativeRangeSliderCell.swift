import AppKit

/// Draws both endpoints with AppKit's own slider rendering and geometry.
/// The host slider owns interaction; this cell's `doubleValue` is the upper endpoint.
internal final class NativeRangeSliderCell: NSSliderCell {
    var lowerValue: Double = 25
    var activeHandle: SliderRange.Handle = .lower
    var isDraggingHandle = false
    var rendersContent = true

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if rendersContent { super.draw(withFrame: cellFrame, in: controlView) }
    }

    func knobRect(for handle: SliderRange.Handle, flipped: Bool) -> NSRect {
        nativeKnobRect(at: handle == .lower ? lowerValue : doubleValue, flipped: flipped)
    }

    func endpointKnobRect(isMaximum: Bool, flipped: Bool) -> NSRect {
        nativeKnobRect(at: isMaximum ? maxValue : minValue, flipped: flipped)
    }

    private func nativeKnobRect(at value: Double, flipped: Bool) -> NSRect {
        let savedValue = doubleValue
        defer { doubleValue = savedValue }
        doubleValue = value
        return super.knobRect(flipped: flipped)
    }

    override func drawKnob(_ knobRect: NSRect) {
        let flipped = controlView?.isFlipped ?? true
        let lowerRect = self.knobRect(for: .lower, flipped: flipped)
        let upperRect = self.knobRect(for: .upper, flipped: flipped)
        let savedFocus = showsFirstResponder
        let savedHighlight = isHighlighted
        defer {
            showsFirstResponder = savedFocus
            isHighlighted = savedHighlight
        }

        // Paint the active endpoint last so it remains visible when they overlap.
        let handles: [SliderRange.Handle] = activeHandle == .lower ? [.upper, .lower] : [.lower, .upper]
        for handle in handles {
            showsFirstResponder = savedFocus && handle == activeHandle
            isHighlighted = isEnabled && isDraggingHandle && handle == activeHandle
            super.drawKnob(handle == .lower ? lowerRect : upperRect)
        }
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        if #available(macOS 26.0, *) {
            // NSSlider.neutralValue supplies the lower endpoint on modern AppKit.
            super.drawBar(inside: rect, flipped: flipped)
            return
        }

        // Earlier AppKit only fills from minValue. Render two disjoint pieces:
        // an empty native bar before the lower endpoint, and the ordinary native
        // bar after it. Clipping preserves the system's colors, shape and texture.
        let lowerCenter = knobRect(for: .lower, flipped: flipped).midX
        let clippingBounds = (controlView?.bounds ?? rect).union(rect)
        let split = min(clippingBounds.maxX, max(clippingBounds.minX, lowerCenter))
        let leftClip = NSRect(x: clippingBounds.minX, y: clippingBounds.minY,
                              width: split - clippingBounds.minX, height: clippingBounds.height)
        let rightClip = NSRect(x: split, y: clippingBounds.minY,
                               width: clippingBounds.maxX - split, height: clippingBounds.height)
        let savedValue = doubleValue
        defer { doubleValue = savedValue }

        if !leftClip.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: leftClip).addClip()
            doubleValue = minValue
            super.drawBar(inside: rect, flipped: flipped)
            NSGraphicsContext.restoreGraphicsState()
        }
        doubleValue = savedValue
        if !rightClip.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rightClip).addClip()
            super.drawBar(inside: rect, flipped: flipped)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
