// KlariVision macOS — canlı pitch verisinin müzikal ve görsel sunumu.
// Makam/karar bağlamı ve Sol klarnet dönüşümü yalnız etikettir; duyulan Hz'i
// değiştirmez. SwiftUI tüner anlık durumu, kalıcı WKWebView uzun eğriyi çizer.
// WebView kimliği yeniden boyutlandırmada korunur.

import AppKit
import Foundation
import QuartzCore
import SwiftUI
import WebKit
import os

enum LiveScale: String, CaseIterable, Identifiable {
    case major, minor, nihavent, kurdi, ussak, hicaz, kurdilihicazkar, hicazkar

    var id: String { rawValue }

    var title: String {
        [
            "major": "Majör", "minor": "Minör", "nihavent": "Nihavend", "kurdi": "Kürdi",
            "ussak": "Uşşak", "hicaz": "Hicaz", "kurdilihicazkar": "Kürdilihicazkâr", "hicazkar": "Hicazkâr",
        ][rawValue] ?? rawValue
    }

    /// Major/minor use concert-pitch names. Turkish makam guides use the
    /// written pitch for a Sol clarinet, while the graph itself stays in the
    /// measured, sounding Hz domain.
    var usesSolClarinetNotation: Bool {
        switch self {
        case .major, .minor:
            return false
        case .nihavent, .kurdi, .ussak, .hicaz, .kurdilihicazkar, .hicazkar:
            return true
        }
    }

    func displayedPitchClass(forSoundingPitchClass pitchClass: Int) -> Int {
        pitchClass + (usesSolClarinetNotation ? -7 : 0)
    }

    func soundingPitchClass(forDisplayedPitchClass pitchClass: Int) -> Int {
        pitchClass + (usesSolClarinetNotation ? 7 : 0)
    }

    var intervals: [Double] {
        switch self {
        case .major: return [9, 9, 4, 9, 9, 9, 4]
        case .minor, .nihavent: return [9, 4, 9, 9, 4, 9, 9]
        case .kurdi, .kurdilihicazkar: return [4, 9, 9, 9, 4, 9, 9]
        case .ussak: return [8, 5, 9, 9, 4, 9, 9]
        case .hicaz: return [5, 12, 5, 9, 8, 5, 9]
        case .hicazkar: return [5, 12, 5, 9, 5, 12, 5]
        }
    }
}

enum LiveMakamIntervals {
    static let storageKey = "klarivision-live-makam-intervals-v1"
    static let makamScales: [LiveScale] = [.nihavent, .kurdi, .ussak, .hicaz, .kurdilihicazkar, .hicazkar]

    static var defaults: [String: [Int]] {
        Dictionary(uniqueKeysWithValues: makamScales.map { scale in
            (scale.rawValue, scale.intervals.map { Int($0) })
        })
    }

    static func load() -> [String: [Int]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([String: [Int]].self, from: data),
              isValid(stored) else {
            return defaults
        }
        return stored
    }

    static func save(_ values: [String: [Int]]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func isValid(_ values: [String: [Int]]) -> Bool {
        makamScales.allSatisfy { scale in
            guard let intervals = values[scale.rawValue], intervals.count == 7 else { return false }
            return intervals.allSatisfy { (1...13).contains($0) } && intervals.reduce(0, +) == 53
        }
    }
}

struct LiveTunerTarget: Hashable {
    let label: String
    let frequency: Double
    let centOffset: Double
    let usesKoma: Bool

    var komaOffset: Double { centOffset * 53 / 1_200 }
}

/// Uses the same selected scale-degree guide as the live graph. Majör/minör
/// therefore target the closest degree of the selected scale, while makams
/// target the closest user-configured koma degree.
func liveTunerTarget(
    for frequency: Double,
    scale: LiveScale,
    tonic: Int,
    intervals: [Int]? = nil
) -> LiveTunerTarget? {
    guard frequency.isFinite, frequency > 0,
          let nearest = pitchGuide(scale: scale, tonic: tonic, intervals: intervals)
            .min(by: { abs(log2(frequency / $0.frequency)) < abs(log2(frequency / $1.frequency)) }) else {
        return nil
    }
    let label = scale.usesSolClarinetNotation
        ? nearest.label
        : approximateNoteName(for: nearest.frequency, scale: scale)
    return LiveTunerTarget(
        label: label,
        frequency: nearest.frequency,
        centOffset: 1_200 * log2(frequency / nearest.frequency),
        usesKoma: scale.usesSolClarinetNotation
    )
}

struct TunerRulerTick: Hashable {
    let centOffset: Double
    let isMajor: Bool
}

struct TunerRulerLabel: Hashable {
    enum Kind: Hashable {
        case chromatic
        case makam
    }

    let label: String
    let centOffset: Double
    let kind: Kind
}

/// The ruler is expressed in cents relative to the selected target.  Its
/// visible interval follows the measured pitch, so the fixed pointer always
/// has two chromatic semitones of context on either side.
struct TunerRulerModel: Hashable {
    static let halfVisibleRange = 200.0

    let target: LiveTunerTarget
    let scale: LiveScale
    let tonic: Int
    let intervals: [Int]

    var visibleCentRange: ClosedRange<Double> {
        (target.centOffset - Self.halfVisibleRange)...(target.centOffset + Self.halfVisibleRange)
    }

    var ticks: [TunerRulerTick] {
        if target.usesKoma {
            let komaWidth = 1_200.0 / 53.0
            let first = Int(floor(visibleCentRange.lowerBound / komaWidth))
            let last = Int(ceil(visibleCentRange.upperBound / komaWidth))
            return (first...last).map { koma in
                TunerRulerTick(centOffset: Double(koma) * komaWidth, isMajor: koma % 4 == 0)
            }
        }

        let first = Int(floor(visibleCentRange.lowerBound / 10)) * 10
        let last = Int(ceil(visibleCentRange.upperBound / 10)) * 10
        return stride(from: first, through: last, by: 10).map { cent in
            TunerRulerTick(centOffset: Double(cent), isMajor: cent % 50 == 0)
        }
    }

    var chromaticLabels: [TunerRulerLabel] {
        let first = Int(floor(visibleCentRange.lowerBound / 100)) * 100
        let last = Int(ceil(visibleCentRange.upperBound / 100)) * 100
        return stride(from: first, through: last, by: 100).map { cent in
            let frequency = target.frequency * pow(2, Double(cent) / 1_200)
            return TunerRulerLabel(
                label: enharmonicTunerNoteName(for: frequency, scale: scale),
                centOffset: Double(cent),
                kind: .chromatic
            )
        }
    }

    var makamLabels: [TunerRulerLabel] {
        guard target.usesKoma else { return [] }
        return pitchGuide(scale: scale, tonic: tonic, intervals: intervals).compactMap { line in
            let offset = 1_200 * log2(line.frequency / target.frequency)
            guard visibleCentRange.contains(offset) else { return nil }
            return TunerRulerLabel(label: line.label, centOffset: offset, kind: .makam)
        }
    }
}

func enharmonicTunerNoteName(for frequency: Double, scale: LiveScale) -> String {
    guard frequency.isFinite, frequency > 0 else { return "" }
    let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
    let displayedPitchClass = scale.displayedPitchClass(forSoundingPitchClass: midi % 12)
    let octave = midi / 12 - 1
    let names = [
        "Do", "Do♯ / Re♭", "Re", "Re♯ / Mi♭", "Mi", "Fa",
        "Fa♯ / Sol♭", "Sol", "Sol♯ / La♭", "La", "La♯ / Si♭", "Si",
    ]
    return "\(names[(displayedPitchClass % 12 + 12) % 12])\(octave)"
}

/// Compact, fixed-pointer tuner for live practice. Its triangle never moves;
/// the pitch ruler moves beneath it so the centre always means the selected
/// scale or makam degree exactly.
struct TunerPanel: View {
    let frequency: Double?
    let scale: LiveScale
    let tonic: Int
    let intervals: [Int]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var target: LiveTunerTarget? {
        guard let frequency else { return nil }
        return liveTunerTarget(for: frequency, scale: scale, tonic: tonic, intervals: intervals)
    }

    var body: some View {
        Canvas { context, size in
            if let target {
                drawTuner(&context, size: size, target: target)
            } else {
                drawEmptyTuner(&context, size: size)
            }
        }
        .frame(maxWidth: 420)
        .frame(height: 132)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
        .accessibilityLabel("Tüner")
        .accessibilityValue(target.map { item in
            item.usesKoma
                ? "\(item.label), \(String(format: "%+.1f", item.komaOffset)) koma"
                : "\(item.label), \(String(format: "%+.1f", item.centOffset)) cent"
        } ?? "Ses bekleniyor")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: target?.centOffset ?? 0)
    }

    private func drawTuner(_ context: inout GraphicsContext, size: CGSize, target: LiveTunerTarget) {
        let ruler = TunerRulerModel(target: target, scale: scale, tonic: tonic, intervals: intervals)
        let centreX = size.width / 2
        let rulerY = size.height - 42
        let pointsPerCent = size.width / CGFloat(TunerRulerModel.halfVisibleRange * 2)
        let offset = -target.centOffset * pointsPerCent
        let markerColor: Color = abs(target.centOffset) <= 8 ? .green : .orange

        drawText("\(scale.title) · \(noteName(tonic)) karar", in: &context, at: CGPoint(x: 12, y: 10), font: .caption2.weight(.medium), color: .secondary, anchor: .topLeading)
        drawText(String(format: "%.1f Hz", frequency ?? 0), in: &context, at: CGPoint(x: size.width - 12, y: 10), font: .caption2.monospacedDigit(), color: .secondary, anchor: .topTrailing)
        drawText(target.label, in: &context, at: CGPoint(x: centreX, y: 28), font: .system(size: 24, weight: .medium, design: .rounded), color: .primary)
        let offsetText = target.usesKoma
            ? String(format: "%+.1f koma", target.komaOffset)
            : String(format: "%+.1f cent", target.centOffset)
        drawText(offsetText, in: &context, at: CGPoint(x: centreX, y: 49), font: .caption2.monospacedDigit().weight(.semibold), color: markerColor)
        drawBaseline(in: &context, width: size.width, rulerY: rulerY)
        drawRulerTicks(ruler.ticks, in: &context, width: size.width, centreX: centreX, rulerY: rulerY, pointsPerCent: pointsPerCent, offset: offset)
        drawRulerLabels(ruler.chromaticLabels, in: &context, width: size.width, centreX: centreX, y: rulerY + 15, pointsPerCent: pointsPerCent, offset: offset, font: .caption2.weight(.medium), color: .primary)
        drawRulerLabels(ruler.makamLabels, in: &context, width: size.width, centreX: centreX, y: rulerY + 31, pointsPerCent: pointsPerCent, offset: offset, font: .caption2.weight(.medium), color: .secondary)
        drawPointer(in: &context, at: CGPoint(x: centreX, y: rulerY), color: markerColor)
    }

    private func drawEmptyTuner(_ context: inout GraphicsContext, size: CGSize) {
        drawText("\(scale.title) · \(noteName(tonic)) karar", in: &context, at: CGPoint(x: 12, y: 10), font: .caption2.weight(.medium), color: .secondary, anchor: .topLeading)
        drawText("Ses yok", in: &context, at: CGPoint(x: size.width / 2, y: size.height / 2), font: .system(size: 22, weight: .medium, design: .rounded), color: .secondary)
    }

    private func drawText(_ value: String, in context: inout GraphicsContext, at point: CGPoint, font: Font, color: Color, anchor: UnitPoint = .center) {
        context.draw(Text(value).font(font).foregroundColor(color), at: point, anchor: anchor)
    }

    private func drawBaseline(in context: inout GraphicsContext, width: CGFloat, rulerY: CGFloat) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: rulerY))
        baseline.addLine(to: CGPoint(x: width, y: rulerY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.72)), lineWidth: 1)
    }

    private func drawRulerTicks(_ ticks: [TunerRulerTick], in context: inout GraphicsContext, width: CGFloat, centreX: CGFloat, rulerY: CGFloat, pointsPerCent: CGFloat, offset: CGFloat) {
        for tick in ticks {
            let x = centreX + CGFloat(tick.centOffset) * pointsPerCent + offset
            guard x >= -8, x <= width + 8 else { continue }
            drawTick(in: &context, x: x, rulerY: rulerY, major: tick.isMajor)
        }
    }

    private func drawRulerLabels(_ labels: [TunerRulerLabel], in context: inout GraphicsContext, width: CGFloat, centreX: CGFloat, y: CGFloat, pointsPerCent: CGFloat, offset: CGFloat, font: Font, color: Color) {
        var occupied: [ClosedRange<CGFloat>] = []
        for item in labels.sorted(by: { abs($0.centOffset - targetCentOffset) < abs($1.centOffset - targetCentOffset) }) {
            let x = centreX + CGFloat(item.centOffset) * pointsPerCent + offset
            let estimatedWidth = max(28, CGFloat(item.label.count) * 5.8)
            let range = (x - estimatedWidth / 2)...(x + estimatedWidth / 2)
            guard range.lowerBound >= 8, range.upperBound <= width - 8,
                  !occupied.contains(where: { $0.overlaps(range) }) else { continue }
            drawText(item.label, in: &context, at: CGPoint(x: x, y: y), font: font, color: color)
            occupied.append(range)
        }
    }

    private var targetCentOffset: Double { target?.centOffset ?? 0 }

    private func drawTick(in context: inout GraphicsContext, x: CGFloat, rulerY: CGFloat, major: Bool) {
        let tickHeight: CGFloat = major ? 16 : 10
        var tick = Path()
        tick.move(to: CGPoint(x: x, y: rulerY - tickHeight / 2))
        tick.addLine(to: CGPoint(x: x, y: rulerY + tickHeight / 2))
        context.stroke(tick, with: .color((major ? Color.primary : .secondary).opacity(major ? 0.82 : 0.58)), lineWidth: major ? 2 : 1)
    }

    private func drawPointer(in context: inout GraphicsContext, at point: CGPoint, color: Color) {
        var pointer = Path()
        pointer.move(to: CGPoint(x: point.x, y: point.y - 1))
        pointer.addLine(to: CGPoint(x: point.x - 8, y: point.y - 13))
        pointer.addLine(to: CGPoint(x: point.x + 8, y: point.y - 13))
        pointer.closeSubpath()
        context.fill(pointer, with: .color(color))
    }
}

struct PitchGraphPoint: Equatable {
    let time: TimeInterval
    let frequency: Double
}

/// Return only the sorted pitch points that can contribute to the current
/// graph window.  Study tracks may contain tens of thousands of points; a
/// linear scan on every display frame makes the scrolling canvas miss frames
/// and appear to flicker even though the presentation clock is smooth.
func pitchGraphVisibleRange(
    points: [PitchGraphPoint],
    windowStart: Double,
    windowEnd: Double,
    margin: Double = 0.05
) -> Range<Int> {
    let lowerTime = windowStart - margin
    let upperTime = windowEnd + margin

    func firstIndex(where predicate: (Double) -> Bool) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(points[middle].time) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }

    let start = firstIndex { $0 >= lowerTime }
    let end = firstIndex { $0 > upperTime }
    return start..<max(start, end)
}

struct PitchGraphPalette {
    let background: Color
    let axis: Color
    let label: Color
    let frame: Color
    let loop: Color
    let playhead: Color

    static func resolve(_ theme: String) -> Self {
        switch theme {
        case "studio":
            return Self(
                background: Color(red: 32 / 255, green: 38 / 255, blue: 45 / 255),
                axis: Color(red: 189 / 255, green: 202 / 255, blue: 213 / 255),
                label: Color(red: 231 / 255, green: 243 / 255, blue: 247 / 255),
                frame: Color(red: 101 / 255, green: 120 / 255, blue: 136 / 255),
                loop: Color(red: 51 / 255, green: 184 / 255, blue: 199 / 255).opacity(0.23),
                playhead: Color(red: 217 / 255, green: 154 / 255, blue: 1)
            )
        case "classic":
            return Self(
                background: Color(red: 1, green: 250 / 255, blue: 241 / 255),
                axis: Color(red: 163 / 255, green: 139 / 255, blue: 105 / 255),
                label: Color(red: 38 / 255, green: 54 / 255, blue: 71 / 255),
                frame: Color(red: 199 / 255, green: 166 / 255, blue: 109 / 255),
                loop: Color(red: 204 / 255, green: 162 / 255, blue: 81 / 255).opacity(0.20),
                playhead: Color(red: 154 / 255, green: 106 / 255, blue: 176 / 255)
            )
        case "focus":
            return Self(
                background: .white,
                axis: Color(red: 61 / 255, green: 72 / 255, blue: 84 / 255),
                label: Color(red: 61 / 255, green: 72 / 255, blue: 84 / 255),
                frame: Color(red: 174 / 255, green: 184 / 255, blue: 195 / 255),
                loop: Color(red: 112 / 255, green: 181 / 255, blue: 235 / 255).opacity(0.20),
                playhead: Color(red: 119 / 255, green: 85 / 255, blue: 184 / 255)
            )
        default:
            return Self(
                background: Color(nsColor: .textBackgroundColor),
                axis: .secondary,
                label: .secondary,
                frame: .secondary.opacity(0.25),
                loop: Color.accentColor.opacity(0.16),
                playhead: Color.accentColor.opacity(0.55)
            )
        }
    }
}

struct PitchGraphRenderState: Equatable {
    let points: [PitchGraphPoint]
    let appearance: GraphAppearance
    let theme: String
    let scale: LiveScale
    let tonic: Int
    let makamIntervals: [Int]
    let windowStart: Double
    let windowEnd: Double
    let verticalCenter: Double
    let verticalSpan: Double
    let playheadTime: Double?
    let loopA: Double?
    let loopB: Double?
    let loopEnabled: Bool
    let timeTickStep: Double
    let maximumContinuousJumpCents: Double?
    let includesGapAtLimit: Bool
    let emptyMessage: String
    var animates = false
    var fixedContentRange: ClosedRange<Double>? = nil
    var leftInset = 86.0
    var rightInset = 18.0
    var topInset = 16.0
    var bottomInset = 28.0

    var duration: Double { max(0.001, windowEnd - windowStart) }

    func requiresPathRebuild(comparedWith previous: Self?) -> Bool {
        guard let previous else { return true }
        return pointRevision != previous.pointRevision
            || appearance != previous.appearance
            || theme != previous.theme
            || scale != previous.scale
            || tonic != previous.tonic
            || makamIntervals != previous.makamIntervals
            || abs(duration - previous.duration) > 0.000_001
            || verticalSpan != previous.verticalSpan
            || loopA != previous.loopA
            || loopB != previous.loopB
            || loopEnabled != previous.loopEnabled
            || timeTickStep != previous.timeTickStep
            || maximumContinuousJumpCents != previous.maximumContinuousJumpCents
            || includesGapAtLimit != previous.includesGapAtLimit
            || emptyMessage != previous.emptyMessage
            || fixedContentRange != previous.fixedContentRange
            || leftInset != previous.leftInset
            || rightInset != previous.rightInset
            || topInset != previous.topInset
            || bottomInset != previous.bottomInset
    }

    private var pointRevision: PitchGraphPointRevision {
        PitchGraphPointRevision(points)
    }
}

struct PitchGraphPointRevision: Equatable {
    let count: Int
    let first: PitchGraphPoint?
    let middle: PitchGraphPoint?
    let last: PitchGraphPoint?

    init(_ points: [PitchGraphPoint]) {
        count = points.count
        first = points.first
        middle = points.isEmpty ? nil : points[points.count / 2]
        last = points.last
    }
}

struct PitchGraphGeometry {
    static func x(
        for time: Double,
        windowStart: Double,
        duration: Double,
        width: CGFloat
    ) -> CGFloat {
        CGFloat((time - windowStart) / max(0.001, duration)) * max(1, width)
    }

    static func y(
        for frequency: Double,
        verticalCenter: Double,
        verticalSpan: Double,
        height: CGFloat
    ) -> CGFloat {
        let cents = 1_200 * log2(frequency / 440)
        let high = verticalCenter + verticalSpan / 2
        return CGFloat((high - cents) / max(1, verticalSpan)) * max(1, height)
    }
}

struct PitchGraphTimeline {
    static func isDiscontinuity(previous: Double?, current: Double, duration: Double) -> Bool {
        guard let previous else { return false }
        return current < previous - 0.10 || abs(current - previous) > max(0.5, duration * 0.5)
    }
}

struct NativePitchGraphView: NSViewRepresentable {
    let points: [PitchGraphPoint]
    let appearance: GraphAppearance
    let theme: String
    let scale: LiveScale
    let tonic: Int
    let makamIntervals: [Int]
    let windowStart: Double
    let windowEnd: Double
    let verticalCenter: Double
    let verticalSpan: Double
    let playheadTime: Double?
    let loopA: Double?
    let loopB: Double?
    let loopEnabled: Bool
    let timeTickStep: Double
    let maximumContinuousJumpCents: Double?
    let includesGapAtLimit: Bool
    let emptyMessage: String
    var presentationTime: (() -> Double)? = nil
    var windowStartAtPresentationTime: ((Double) -> Double)? = nil
    var animates = false
    var fixedContentRange: ClosedRange<Double>? = nil
    var onScroll: ((LiveGraphScrollEvent) -> Void)? = nil
    var onVerticalDrag: ((LiveGraphVerticalDragEvent) -> Void)? = nil
    var onDragStarted: (() -> Void)? = nil
    var onHorizontalDrag: ((LiveGraphHorizontalDragEvent) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    var onClick: (() -> Void)? = nil

    private var state: PitchGraphRenderState {
        PitchGraphRenderState(
            points: points,
            appearance: appearance,
            theme: theme,
            scale: scale,
            tonic: tonic,
            makamIntervals: makamIntervals,
            windowStart: windowStart,
            windowEnd: windowEnd,
            verticalCenter: verticalCenter,
            verticalSpan: verticalSpan,
            playheadTime: playheadTime,
            loopA: loopA,
            loopB: loopB,
            loopEnabled: loopEnabled,
            timeTickStep: timeTickStep,
            maximumContinuousJumpCents: maximumContinuousJumpCents,
            includesGapAtLimit: includesGapAtLimit,
            emptyMessage: emptyMessage,
            animates: animates,
            fixedContentRange: fixedContentRange
        )
    }

    func makeNSView(context: Context) -> PitchGraphNSView {
        let view = PitchGraphNSView(frame: .zero)
        configure(view)
        view.apply(state)
        return view
    }

    func updateNSView(_ view: PitchGraphNSView, context: Context) {
        configure(view)
        view.apply(state)
    }

    private func configure(_ view: PitchGraphNSView) {
        view.presentationTime = presentationTime
        view.windowStartAtPresentationTime = windowStartAtPresentationTime
        view.onScroll = onScroll
        view.onVerticalDrag = onVerticalDrag
        view.onDragStarted = onDragStarted
        view.onHorizontalDrag = onHorizontalDrag
        view.onDragEnded = onDragEnded
        view.onClick = onClick
    }
}

final class PitchGraphNSView: NSView {
    var presentationTime: (() -> Double)?
    var windowStartAtPresentationTime: ((Double) -> Double)?
    var onScroll: ((LiveGraphScrollEvent) -> Void)?
    var onVerticalDrag: ((LiveGraphVerticalDragEvent) -> Void)?
    var onDragStarted: (() -> Void)?
    var onHorizontalDrag: ((LiveGraphHorizontalDragEvent) -> Void)?
    var onDragEnded: (() -> Void)?
    var onClick: (() -> Void)?

    private let guideLayer = CAShapeLayer()
    private let guideTextLayer = CALayer()
    private let timeGridLayer = CAShapeLayer()
    private let timeTextLayer = CALayer()
    private let plotClipLayer = CALayer()
    private let plotContentLayer = CALayer()
    private let loopLayer = CAShapeLayer()
    private let curveLayer = CAShapeLayer()
    private let markerALayer = CAShapeLayer()
    private let markerBLayer = CAShapeLayer()
    private let markerTextLayer = CALayer()
    private let playheadLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let emptyTextLayer = CATextLayer()
    private var displayLink: CADisplayLink?
    private var state: PitchGraphRenderState?
    private var pendingState: PitchGraphRenderState?
    private var baseWindowStart = 0.0
    private var baseVerticalCenter = 0.0
    private var lastPresentationTime: Double?
    private var lastLayoutSize = CGSize.zero
    private var lastDisplayTimestamp: CFTimeInterval?
    private var lastDragLocation: CGPoint?
    private var initialDragLocation: CGPoint?
    private var dragged = false
    #if DEBUG
    private let performanceLog = OSLog(subsystem: "com.aykerme.KlariVisionNative", category: "PitchGraph")
    #endif
    private(set) var pathRebuildCount = 0
    private(set) var maximumDisplayInterval = 0.0
    private(set) var slowDisplayIntervals = 0
    private(set) var renderedChartRect = CGRect.zero
    private(set) var renderedPlayheadX: CGFloat?
    private(set) var renderedContentFrame = CGRect.zero

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .never
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .never
        setupLayers()
    }

    private func setupLayers() {
        guard let root = layer else { return }
        root.addSublayer(guideLayer)
        root.addSublayer(guideTextLayer)
        root.addSublayer(timeGridLayer)
        root.addSublayer(timeTextLayer)
        root.addSublayer(plotClipLayer)
        plotClipLayer.masksToBounds = true
        plotClipLayer.addSublayer(plotContentLayer)
        plotContentLayer.addSublayer(loopLayer)
        plotContentLayer.addSublayer(curveLayer)
        plotContentLayer.addSublayer(markerALayer)
        plotContentLayer.addSublayer(markerBLayer)
        plotContentLayer.addSublayer(markerTextLayer)
        root.addSublayer(playheadLayer)
        root.addSublayer(borderLayer)
        root.addSublayer(emptyTextLayer)

        [guideLayer, timeGridLayer, loopLayer, curveLayer, markerALayer, markerBLayer, playheadLayer, borderLayer].forEach {
            $0.fillColor = NSColor.clear.cgColor
        }
        curveLayer.lineWidth = 1.7
        curveLayer.lineCap = .round
        curveLayer.lineJoin = .round
        emptyTextLayer.alignmentMode = .center
        emptyTextLayer.fontSize = 13
    }

    func apply(_ newState: PitchGraphRenderState) {
        let oldState = state
        state = newState
        refreshDisplayLink()
        if newState.requiresPathRebuild(comparedWith: oldState) {
            if newState.animates, displayLink != nil, oldState != nil {
                pendingState = newState
            } else {
                pendingState = nil
                rebuildLayers(at: currentWindowStart(for: currentPresentationTime()))
            }
        } else {
            updateDynamicLayers(time: currentPresentationTime())
        }
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        rebuildLayers(at: currentWindowStart(for: currentPresentationTime()))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            invalidateDisplayLink()
        } else {
            updateContentsScale()
            refreshDisplayLink()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
        rebuildLayers(at: currentWindowStart(for: currentPresentationTime()))
    }

    private func refreshDisplayLink() {
        guard window != nil, state?.animates == true else {
            displayLink?.isPaused = true
            return
        }
        if displayLink == nil {
            let link = self.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastDisplayTimestamp = nil
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        if let previous = lastDisplayTimestamp {
            let interval = link.timestamp - previous
            maximumDisplayInterval = max(maximumDisplayInterval, interval)
            if interval > 1.0 / 30.0 { slowDisplayIntervals += 1 }
        }
        lastDisplayTimestamp = link.timestamp

        if pendingState != nil {
            pendingState = nil
            rebuildLayers(at: currentWindowStart(for: currentPresentationTime()))
        }
        renderFrame(
            time: currentPresentationTime(),
            windowStart: currentWindowStart(for: currentPresentationTime())
        )
    }

    private func renderFrame(time: Double, windowStart: Double) {
        if state?.fixedContentRange != nil {
            updateDynamicLayers(time: time)
            lastPresentationTime = time
            return
        }
        if PitchGraphTimeline.isDiscontinuity(
            previous: lastPresentationTime,
            current: time,
            duration: state?.duration ?? 1
        ) {
            rebuildLayers(at: windowStart, presentationTime: time)
        } else if let state, abs(windowStart - baseWindowStart) > state.duration * 0.35 {
            rebuildLayers(at: windowStart, presentationTime: time)
        } else if let state, abs(state.verticalCenter - baseVerticalCenter) > state.verticalSpan * 0.35 {
            rebuildLayers(at: windowStart, presentationTime: time)
        } else {
            updateDynamicLayers(time: time)
        }
        lastPresentationTime = time
    }

    func renderPresentationForTesting(time: Double, windowStart: Double) {
        renderFrame(time: time, windowStart: windowStart)
    }

    private func currentPresentationTime() -> Double {
        let value = presentationTime?() ?? state?.playheadTime ?? 0
        return value.isFinite ? value : 0
    }

    private func currentWindowStart(for time: Double) -> Double {
        let value = windowStartAtPresentationTime?(time) ?? state?.windowStart ?? 0
        return value.isFinite ? value : (state?.windowStart ?? 0)
    }

    private var chartRect: CGRect {
        guard let state else { return .zero }
        return CGRect(
            x: state.leftInset,
            y: state.topInset,
            width: max(1, bounds.width - state.leftInset - state.rightInset),
            height: max(1, bounds.height - state.topInset - state.bottomInset)
        )
    }

    private func rebuildLayers(at windowStart: Double, presentationTime: Double? = nil) {
        guard let state, bounds.width > 0, bounds.height > 0 else { return }
        #if DEBUG
        os_signpost(.begin, log: performanceLog, name: "Pitch graph path rebuild")
        defer { os_signpost(.end, log: performanceLog, name: "Pitch graph path rebuild") }
        #endif
        pathRebuildCount += 1
        baseWindowStart = state.fixedContentRange?.lowerBound ?? windowStart
        baseVerticalCenter = state.verticalCenter
        let chart = chartRect
        renderedChartRect = chart
        let palette = PitchGraphPalette.resolve(state.theme)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // `frame` is derived from bounds/position/transform and must not be
        // assigned while the previous scrolling transform is still active.
        // The first cache rebase occurs near 4.2 s for the default 12 s
        // window; keeping that transform here made the new content jump back
        // to its old origin even though the media clock continued normally.
        timeGridLayer.transform = CATransform3DIdentity
        timeTextLayer.transform = CATransform3DIdentity
        plotContentLayer.transform = CATransform3DIdentity
        guideLayer.transform = CATransform3DIdentity
        guideTextLayer.transform = CATransform3DIdentity
        layer?.backgroundColor = NSColor(palette.background).cgColor
        layer?.contentsScale = scale
        guideLayer.frame = chart
        guideTextLayer.frame = bounds
        timeGridLayer.frame = bounds
        timeTextLayer.frame = bounds
        plotClipLayer.frame = chart
        plotContentLayer.frame = plotClipLayer.bounds
        renderedContentFrame = plotContentLayer.frame
        [loopLayer, curveLayer, markerALayer, markerBLayer, markerTextLayer].forEach { $0.frame = plotContentLayer.bounds }
        playheadLayer.frame = chart
        borderLayer.frame = chart
        emptyTextLayer.frame = CGRect(x: chart.minX, y: chart.midY - 10, width: chart.width, height: 22)
        emptyTextLayer.string = state.points.isEmpty ? state.emptyMessage : nil
        emptyTextLayer.foregroundColor = NSColor(palette.label).cgColor
        emptyTextLayer.contentsScale = scale

        rebuildGuides(state: state, palette: palette, scale: scale, chart: chart)
        rebuildTimeAxis(state: state, palette: palette, scale: scale, chart: chart)
        rebuildPlot(state: state, palette: palette, scale: scale, chart: chart)

        borderLayer.path = CGPath(rect: borderLayer.bounds, transform: nil)
        borderLayer.strokeColor = NSColor(palette.frame).cgColor
        borderLayer.lineWidth = 1
        updateDynamicLayers(time: presentationTime ?? currentPresentationTime())
        CATransaction.commit()
    }

    private func rebuildGuides(state: PitchGraphRenderState, palette: PitchGraphPalette, scale: CGFloat, chart: CGRect) {
        let path = CGMutablePath()
        clearSublayers(of: guideTextLayer)
        for line in pitchGuide(scale: state.scale, tonic: state.tonic, intervals: state.makamIntervals) {
            let y = PitchGraphGeometry.y(
                for: line.frequency,
                verticalCenter: state.verticalCenter,
                verticalSpan: state.verticalSpan,
                height: chart.height
            )
            guard y >= -4, y <= chart.height + 4 else { continue }
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: chart.width, y: y))
            let text = textLayer(
                pitchGraphNoteLabel(line.label, frequency: line.frequency),
                color: NSColor(palette.label),
                fontSize: 11,
                scale: scale,
                alignment: .right
            )
            text.frame = CGRect(x: 2, y: chart.minY + y - 8, width: max(1, state.leftInset - 9), height: 16)
            guideTextLayer.addSublayer(text)
        }
        guideLayer.path = path
        guideLayer.strokeColor = NSColor(state.appearance.noteGuideColor.opacity(0.42)).cgColor
        guideLayer.lineWidth = 1
    }

    private func rebuildTimeAxis(state: PitchGraphRenderState, palette: PitchGraphPalette, scale: CGFloat, chart: CGRect) {
        clearSublayers(of: timeTextLayer)
        let path = CGMutablePath()
        let overscan = state.duration * 0.5
        let contentStart = state.fixedContentRange?.lowerBound ?? (baseWindowStart - overscan)
        let contentEnd = state.fixedContentRange?.upperBound ?? (baseWindowStart + state.duration + overscan)
        let tickStep = max(0.001, state.timeTickStep)
        var tick = max(0, ceil(contentStart / tickStep) * tickStep)
        while tick <= contentEnd + 0.0001 {
            let x = chart.minX + PitchGraphGeometry.x(
                for: tick,
                windowStart: baseWindowStart,
                duration: state.duration,
                width: chart.width
            )
            path.move(to: CGPoint(x: x, y: chart.minY))
            path.addLine(to: CGPoint(x: x, y: chart.maxY))
            let text = textLayer(
                "\(Int(tick.rounded())) sn",
                color: NSColor(palette.label),
                fontSize: 9,
                scale: scale,
                alignment: .center
            )
            text.frame = CGRect(x: x - 35, y: chart.maxY + 5, width: 70, height: 14)
            timeTextLayer.addSublayer(text)
            tick += tickStep
        }
        timeGridLayer.path = path
        timeGridLayer.strokeColor = NSColor(palette.axis.opacity(0.22)).cgColor
        timeGridLayer.lineWidth = 1
    }

    private func rebuildPlot(state: PitchGraphRenderState, palette: PitchGraphPalette, scale: CGFloat, chart: CGRect) {
        let overscan = state.duration * 0.5
        let cachedStart = state.fixedContentRange?.lowerBound ?? (baseWindowStart - overscan)
        let cachedEnd = state.fixedContentRange?.upperBound ?? (baseWindowStart + state.duration + overscan)
        let curve = CGMutablePath()
        var previous: PitchGraphPoint?
        for index in pitchGraphVisibleRange(
            points: state.points,
            windowStart: cachedStart,
            windowEnd: cachedEnd
        ) {
            let point = state.points[index]
            let location = CGPoint(
                x: PitchGraphGeometry.x(
                    for: point.time,
                    windowStart: baseWindowStart,
                    duration: state.duration,
                    width: chart.width
                ),
                y: PitchGraphGeometry.y(
                    for: point.frequency,
                    verticalCenter: state.verticalCenter,
                    verticalSpan: state.verticalSpan,
                    height: chart.height
                )
            )
            let continuous: Bool
            if let previous {
                let elapsed = point.time - previous.time
                let accepted = state.includesGapAtLimit
                    ? elapsed > 0 && elapsed <= 0.040
                    : elapsed > 0 && elapsed < 0.040
                let jump = abs(1_200 * log2(point.frequency / previous.frequency))
                continuous = accepted && (state.maximumContinuousJumpCents.map { jump < $0 } ?? true)
            } else {
                continuous = false
            }
            continuous ? curve.addLine(to: location) : curve.move(to: location)
            previous = point
        }
        curveLayer.path = curve
        curveLayer.strokeColor = NSColor(state.appearance.pitchColor).cgColor

        let loop = CGMutablePath()
        if state.loopEnabled, let loopA = state.loopA, let loopB = state.loopB {
            let start = PitchGraphGeometry.x(for: loopA, windowStart: baseWindowStart, duration: state.duration, width: chart.width)
            let end = PitchGraphGeometry.x(for: loopB, windowStart: baseWindowStart, duration: state.duration, width: chart.width)
            if end > start { loop.addRect(CGRect(x: start, y: 0, width: end - start, height: chart.height)) }
        }
        loopLayer.path = loop
        loopLayer.fillColor = NSColor(palette.loop).cgColor

        clearSublayers(of: markerTextLayer)
        func addMarker(_ time: Double?, label: String, color: NSColor, layer: CAShapeLayer) {
            let path = CGMutablePath()
            guard let time, time >= cachedStart, time <= cachedEnd else {
                layer.path = path
                return
            }
            let x = PitchGraphGeometry.x(for: time, windowStart: baseWindowStart, duration: state.duration, width: chart.width)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: chart.height))
            layer.path = path
            layer.strokeColor = color.cgColor
            layer.lineWidth = 1.5
            let text = textLayer(label, color: color, fontSize: 12, scale: scale, alignment: .center)
            text.frame = CGRect(x: x - 12, y: 5, width: 24, height: 17)
            markerTextLayer.addSublayer(text)
        }
        addMarker(
            state.loopA,
            label: "A",
            color: NSColor(red: 21 / 255, green: 115 / 255, blue: 71 / 255, alpha: 1),
            layer: markerALayer
        )
        addMarker(
            state.loopB,
            label: "B",
            color: NSColor(red: 189 / 255, green: 91 / 255, blue: 0, alpha: 1),
            layer: markerBLayer
        )
    }

    private func updateDynamicLayers(time: Double) {
        guard let state else { return }
        let windowStart = currentWindowStart(for: time)
        let chart = chartRect
        let shift = -PitchGraphGeometry.x(
            for: windowStart,
            windowStart: baseWindowStart,
            duration: state.duration,
            width: chart.width
        )
        // Vertical follow-curve panning is applied as a cheap transform rather
        // than baked into the path, mirroring the horizontal `shift` above, so
        // the "follow curve" feature doesn't force a full `rebuildLayers` on
        // every playback snapshot. See `PitchGraphGeometry.y`: a change in
        // `verticalCenter` alone (span held constant) is linear in pixels.
        let verticalShift = (state.verticalCenter - baseVerticalCenter)
            * chart.height / max(1, state.verticalSpan)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = CATransform3DMakeTranslation(shift, verticalShift, 0)
        timeGridLayer.transform = CATransform3DMakeTranslation(shift, 0, 0)
        timeTextLayer.transform = CATransform3DMakeTranslation(shift, 0, 0)
        plotContentLayer.transform = transform
        let verticalOnly = CATransform3DMakeTranslation(0, verticalShift, 0)
        guideLayer.transform = verticalOnly
        guideTextLayer.transform = verticalOnly
        renderedContentFrame = plotContentLayer.frame

        let playheadX = PitchGraphGeometry.x(
            for: time,
            windowStart: windowStart,
            duration: state.duration,
            width: chart.width
        )
        let playhead = CGMutablePath()
        if playheadX >= 0, playheadX <= chart.width {
            playhead.move(to: CGPoint(x: playheadX, y: 0))
            playhead.addLine(to: CGPoint(x: playheadX, y: chart.height))
            renderedPlayheadX = playheadX
        } else {
            renderedPlayheadX = nil
        }
        playheadLayer.path = playhead
        playheadLayer.strokeColor = NSColor(PitchGraphPalette.resolve(state.theme).playhead).cgColor
        playheadLayer.lineWidth = 1.5
        CATransaction.commit()
    }

    private func textLayer(
        _ value: String,
        color: NSColor,
        fontSize: CGFloat,
        scale: CGFloat,
        alignment: CATextLayerAlignmentMode
    ) -> CATextLayer {
        let text = CATextLayer()
        text.string = value
        text.foregroundColor = color.cgColor
        text.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        text.fontSize = fontSize
        text.alignmentMode = alignment
        text.contentsScale = scale
        return text
    }

    private func clearSublayers(of layer: CALayer) {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func apply(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(apply)
        }
        if let layer { apply(layer) }
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onScroll?(LiveGraphScrollEvent(
            deltaY: event.scrollingDeltaY,
            shiftPressed: event.modifierFlags.contains(.shift),
            location: location,
            size: bounds.size
        ))
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastDragLocation = location
        initialDragLocation = location
        dragged = false
        onDragStarted?()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let previous = lastDragLocation else { lastDragLocation = location; return }
        let deltaY = location.y - previous.y
        lastDragLocation = location
        guard let initialDragLocation else { return }
        let translationX = location.x - initialDragLocation.x
        let translationY = location.y - initialDragLocation.y
        if abs(translationX) >= 4 || abs(translationY) >= 4 { dragged = true }
        if onHorizontalDrag != nil, abs(translationX) >= abs(translationY) {
            onHorizontalDrag?(LiveGraphHorizontalDragEvent(translationX: translationX, size: bounds.size))
        } else if abs(deltaY) > 0 {
            onVerticalDrag?(LiveGraphVerticalDragEvent(deltaY: deltaY, size: bounds.size))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
        lastDragLocation = nil
        initialDragLocation = nil
        onDragEnded?()
    }
}

func pitchGraphNoteLabel(_ label: String, frequency: Double) -> String {
    guard !label.contains(where: \.isNumber), frequency.isFinite, frequency > 0 else { return label }
    let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
    return "\(label)\(midi / 12 - 1)"
}

struct LivePitchGraph: View {
    let frames: [LivePitchFrame]
    let appearance: GraphAppearance
    let scale: LiveScale
    let tonic: Int
    let makamIntervals: [Int]
    let followsCurve: Bool
    let graphTime: (TimeInterval) -> TimeInterval
    let graphNow: (TimeInterval) -> TimeInterval
    let isAnimating: Bool
    @Binding var visibleDuration: Double
    @Binding var verticalSpan: Double
    @Binding var verticalCenter: Double
    let onScroll: (LiveGraphScrollEvent) -> Void
    let onVerticalDrag: (LiveGraphVerticalDragEvent) -> Void

    var body: some View {
        let now = Date().timeIntervalSinceReferenceDate
        let end = graphNow(now)
        LiveWebPitchGraph(
            points: frames.map { PitchGraphPoint(time: graphTime($0.time), frequency: $0.frequency) },
            appearance: appearance,
            scale: scale,
            tonic: tonic,
            makamIntervals: makamIntervals,
            graphNow: end,
            isAnimating: isAnimating,
            visibleDuration: visibleDuration,
            verticalCenter: verticalCenter,
            verticalSpan: verticalSpan,
            onScroll: onScroll,
            onVerticalDrag: onVerticalDrag
        )
        .accessibilityLabel("Canlı pitch grafiği")
    }
}

struct LiveWebPitchGraph: NSViewRepresentable {
    let points: [PitchGraphPoint]
    let appearance: GraphAppearance
    let scale: LiveScale
    let tonic: Int
    let makamIntervals: [Int]
    let graphNow: Double
    let isAnimating: Bool
    let visibleDuration: Double
    let verticalCenter: Double
    let verticalSpan: Double
    let onScroll: (LiveGraphScrollEvent) -> Void
    let onVerticalDrag: (LiveGraphVerticalDragEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onVerticalDrag: onVerticalDrag)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "liveGraphInteraction")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.document, baseURL: nil)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onVerticalDrag = onVerticalDrag
        context.coordinator.enqueue(
            points: points,
            guides: pitchGuide(scale: scale, tonic: tonic, intervals: makamIntervals),
            appearance: appearance,
            graphNow: graphNow,
            isAnimating: isAnimating,
            visibleDuration: visibleDuration,
            verticalCenter: verticalCenter,
            verticalSpan: verticalSpan
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "liveGraphInteraction")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onScroll: (LiveGraphScrollEvent) -> Void
        var onVerticalDrag: (LiveGraphVerticalDragEvent) -> Void
        private var pendingScript: String?
        private var scheduled = false
        private var lastSentPointTime = -Double.infinity
        private var pendingLastPointTime: Double?
        private var lastSourceFirstTime: Double?

        init(
            onScroll: @escaping (LiveGraphScrollEvent) -> Void,
            onVerticalDrag: @escaping (LiveGraphVerticalDragEvent) -> Void
        ) {
            self.onScroll = onScroll
            self.onVerticalDrag = onVerticalDrag
        }

        func enqueue(
            points: [PitchGraphPoint],
            guides: [(label: String, frequency: Double, isKarar: Bool)],
            appearance: GraphAppearance,
            graphNow: Double,
            isAnimating: Bool,
            visibleDuration: Double,
            verticalCenter: Double,
            verticalSpan: Double
        ) {
            let sourceFirst = points.first?.time
            let sourceRewound = sourceFirst.map { first in
                lastSourceFirstTime.map { first < $0 - 0.10 } ?? false
            } ?? false
            let timelineRestarted = points.last.map { last in
                last.time < lastSentPointTime - 0.10
            } ?? false
            let reset = sourceRewound || timelineRestarted
            if reset { lastSentPointTime = -Double.infinity }
            lastSourceFirstTime = sourceFirst
            let additions = points.filter { $0.time > lastSentPointTime }
            pendingLastPointTime = additions.last?.time
            let payload: [String: Any] = [
                "reset": reset,
                "points": additions.map { ["t": $0.time, "hz": $0.frequency] },
                "guides": guides.map { ["label": pitchGraphNoteLabel($0.label, frequency: $0.frequency), "hz": $0.frequency, "karar": $0.isKarar] },
                "pitch": appearance.pitchHex,
                "guide": appearance.noteGuideHex,
                "karar": appearance.kararHex,
                "now": graphNow,
                "animating": isAnimating,
                "visibleDuration": visibleDuration,
                "verticalCenter": verticalCenter,
                "verticalSpan": verticalSpan,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            pendingScript = "window.__klariLivePending=\(json);window.KlariLiveGraph?.update(window.__klariLivePending);"
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
                guard let self else { return }
                scheduled = false
                guard let script = pendingScript else { return }
                pendingScript = nil
                if let pendingLastPointTime {
                    lastSentPointTime = pendingLastPointTime
                    self.pendingLastPointTime = nil
                }
                webView?.evaluateJavaScript(script)
            }
        }

        func cancel() {
            pendingScript = nil
            pendingLastPointTime = nil
            scheduled = false
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            let width = (body["width"] as? NSNumber)?.doubleValue ?? 1
            let height = (body["height"] as? NSNumber)?.doubleValue ?? 1
            if kind == "scroll" {
                onScroll(LiveGraphScrollEvent(
                    deltaY: CGFloat((body["deltaY"] as? NSNumber)?.doubleValue ?? 0),
                    shiftPressed: (body["shift"] as? Bool) ?? false,
                    location: CGPoint(
                        x: (body["x"] as? NSNumber)?.doubleValue ?? 0,
                        y: (body["y"] as? NSNumber)?.doubleValue ?? 0
                    ),
                    size: CGSize(width: width, height: height)
                ))
            } else if kind == "verticalDrag" {
                onVerticalDrag(LiveGraphVerticalDragEvent(
                    deltaY: CGFloat((body["deltaY"] as? NSNumber)?.doubleValue ?? 0),
                    size: CGSize(width: width, height: height)
                ))
            }
        }
    }

    static let document = #"""
    <!doctype html><meta charset="utf-8">
    <style>
    :root{color-scheme:light dark}*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
    canvas{display:block;width:100%;height:100%;touch-action:none}
    </style><canvas id="graph"></canvas><script>
    (()=>{
      const c=document.getElementById('graph'),x=c.getContext('2d');
      const s={points:[],guides:[],pitch:'#0A84FF',guide:'#8E8E93',karar:'#E75A5A',now:0,received:performance.now(),animating:false,visibleDuration:12,verticalCenter:0,verticalSpan:2400};
      let dragY=null;
      const resize=()=>{const d=devicePixelRatio||1,w=Math.max(1,c.clientWidth),h=Math.max(1,c.clientHeight);if(c.width!==Math.round(w*d)||c.height!==Math.round(h*d)){c.width=Math.round(w*d);c.height=Math.round(h*d);x.setTransform(d,0,0,d,0,0)}};
      // Sunum saati.  `s.now` SwiftUI body'sinde Date() ile okunur ve
      // Coordinator onu 1/30 sn'lik birleştirme gecikmesiyle yollar; bu
      // gecikme her turda farklı olduğu için saati doğrudan `s.now`a
      // oturtmak pencereyi kare kare ileri geri zıplatır (ölçüm: 500 karede
      // 24 kare geri, tek karede +48 ms sıçrama).  Bunun yerine saat kendi
      // hızıyla akar ve hedefe yalnızca süzülerek yaklaşır: küçük farklar
      // ~0,3 sn'lik bir zaman sabitiyle kapanır, gerçek atlamalar (arama,
      // yeni oturum) 0,35 sn eşiğinin üstünde kaldığı için anında yakalanır.
      const target=()=>s.now+(s.animating?(performance.now()-s.received)/1000:0);
      let shown=null,shownAt=performance.now();
      const advance=()=>{
        const wall=performance.now(),goal=target();
        if(shown===null||!s.animating){shown=goal;shownAt=wall;return shown}
        const flowed=shown+(wall-shownAt)/1000;
        shownAt=wall;
        const error=goal-flowed;
        shown=Math.abs(error)>.35?goal:flowed+error*.05;
        return shown;
      };
      const draw=()=>{
        resize();const w=c.clientWidth,h=c.clientHeight,L=86,R=18,T=16,B=28,cw=Math.max(1,w-L-R),ch=Math.max(1,h-T-B),now=advance(),start=now-s.visibleDuration,high=s.verticalCenter+s.verticalSpan/2;
        const dark=matchMedia('(prefers-color-scheme:dark)').matches,bg=dark?'#20262d':'#ffffff',label=dark?'#e7f3f7':'#3d4854',axis=dark?'#bdcad5':'#3d4854';
        x.fillStyle=bg;x.fillRect(0,0,w,h);x.font='600 11px -apple-system,system-ui';x.textAlign='right';
        const Y=hz=>T+(high-1200*Math.log2(hz/440))/s.verticalSpan*ch,X=t=>L+(t-start)/s.visibleDuration*cw;
        x.strokeStyle=s.guide+'70';x.lineWidth=1;for(const g of s.guides){if(g.karar)continue;const y=Y(g.hz);if(y<T-4||y>h-B+4)continue;x.beginPath();x.moveTo(L,y);x.lineTo(w-R,y);x.stroke();x.fillStyle=label;x.fillText(g.label,L-7,y+4)}x.strokeStyle=s.karar+'C0';x.lineWidth=2;for(const g of s.guides){if(!g.karar)continue;const y=Y(g.hz);if(y<T-4||y>h-B+4)continue;x.beginPath();x.moveTo(L,y);x.lineTo(w-R,y);x.stroke();x.fillStyle=label;x.fillText(g.label,L-7,y+4)}x.lineWidth=1;
        const step=s.visibleDuration<=12?1:s.visibleDuration<=30?2:5;x.font='500 9px -apple-system,system-ui';x.textAlign='center';for(let t=Math.max(0,Math.ceil(start/step)*step);t<=now+.001;t+=step){const xx=X(t);x.strokeStyle=axis+'38';x.beginPath();x.moveTo(xx,T);x.lineTo(xx,h-B);x.stroke();x.fillStyle=label;x.fillText(Math.round(t)+' sn',xx,h-B+15)}
        x.save();x.beginPath();x.rect(L,T,cw,ch);x.clip();x.strokeStyle=s.pitch;x.lineWidth=1.7;x.lineJoin='round';x.lineCap='round';x.beginPath();let p=null;for(const q of s.points){if(q.t<start-.05||q.t>now+.05)continue;const xx=X(q.t),yy=Y(q.hz),ok=p&&q.t-p.t>0&&q.t-p.t<.040&&Math.abs(1200*Math.log2(q.hz/p.hz))<520;ok?x.lineTo(xx,yy):x.moveTo(xx,yy);p=q}x.stroke();x.strokeStyle=dark?'#9a6ab0':'#7755b8';x.lineWidth=1.5;x.beginPath();x.moveTo(w-R,T);x.lineTo(w-R,h-B);x.stroke();x.restore();x.strokeStyle=axis+'66';x.strokeRect(L,T,cw,ch);
        if(!s.points.length){x.fillStyle=label;x.font='13px -apple-system,system-ui';x.textAlign='center';x.fillText('Mikrofonu başlatıp klarnet çalmaya başla.',w/2,h/2)}
        requestAnimationFrame(draw);
      };
      window.KlariLiveGraph={update:v=>{if(v.reset)s.points=[];if(v.points?.length)s.points.push(...v.points);s.points=s.points.filter(p=>p.t>=v.now-65);const {points,reset,...config}=v;Object.assign(s,config);s.received=performance.now()}};
      if(window.__klariLivePending)window.KlariLiveGraph.update(window.__klariLivePending);
      c.addEventListener('wheel',e=>{e.preventDefault();webkit.messageHandlers.liveGraphInteraction.postMessage({kind:'scroll',deltaY:e.deltaY>0?-1:1,shift:e.shiftKey,x:e.offsetX,y:e.offsetY,width:c.clientWidth,height:c.clientHeight})},{passive:false});
      c.addEventListener('pointerdown',e=>{dragY=e.clientY;c.setPointerCapture(e.pointerId)});c.addEventListener('pointermove',e=>{if(dragY===null)return;const d=dragY-e.clientY;dragY=e.clientY;webkit.messageHandlers.liveGraphInteraction.postMessage({kind:'verticalDrag',deltaY:d,width:c.clientWidth,height:c.clientHeight})});c.addEventListener('pointerup',()=>dragY=null);
      requestAnimationFrame(draw);
    })();
    </script>
    """#
}

struct LiveGraphScrollEvent {
    let deltaY: CGFloat
    let shiftPressed: Bool
    let location: CGPoint
    let size: CGSize
}

struct LiveGraphVerticalDragEvent {
    let deltaY: CGFloat
    let size: CGSize
}

struct LiveGraphHorizontalDragEvent {
    let translationX: CGFloat
    let size: CGSize
}

func pitchGuide(scale: LiveScale, tonic: Int, intervals: [Int]? = nil) -> [(label: String, frequency: Double, isKarar: Bool)] {
    var steps = [0.0]
    let guideIntervals = intervals?.map(Double.init) ?? scale.intervals
    for interval in guideIntervals.dropLast() { steps.append(steps.last! + interval) }
    // Match the practice view: a makam's selected karar is written for a Sol
    // clarinet, so its sounding frequency is a perfect fourth higher.
    let soundingTonic = scale.soundingPitchClass(forDisplayedPitchClass: tonic)
    let rootMidi = 60 + ((soundingTonic % 12) + 12) % 12
    return (-3...3).flatMap { octave in
        steps.enumerated().map { degree, step in
            let frequency = 440.0 * pow(2, Double(rootMidi - 69) / 12) * pow(2, Double(octave) + step / 53)
            let label: String
            if scale.usesSolClarinetNotation {
                label = makamNoteLabel(
                    scale.degreeNames(forTonic: tonic)[degree],
                    octave: rootMidi / 12 - 1 + octave,
                    step: step,
                    rootPitchClass: tonic
                )
            } else {
                let displayedPitchClass = tonic + Int((step * 12 / 53).rounded())
                label = noteName(displayedPitchClass)
            }
            return (label, frequency, degree == 0)
        }
    }
}

func nearestPitchGuideNoteName(
    for frequency: Double,
    scale: LiveScale,
    tonic: Int,
    intervals: [Int]? = nil
) -> String {
    guard let nearest = pitchGuide(scale: scale, tonic: tonic, intervals: intervals)
        .min(by: { abs(log2(frequency / $0.frequency)) < abs(log2(frequency / $1.frequency)) }) else {
        return approximateNoteName(for: frequency, scale: scale)
    }
    return nearest.label
}

extension LiveScale {
    /// The practice view spells makam degrees from the selected written tonic,
    /// then expresses their distance from the natural staff note in commas.
    /// Keep that spelling here so the live graph and tuner use the same labels.
    func degreeNames(forTonic tonic: Int) -> [String] {
        let minor: [Int: [String]] = [
            0: ["Do", "Re", "Mi♭", "Fa", "Sol", "La♭", "Si♭"],
            2: ["Re", "Mi", "Fa", "Sol", "La", "Si♭", "Do"],
            4: ["Mi", "Fa♯", "Sol", "La", "Si", "Do", "Re"],
            5: ["Fa", "Sol", "La♭", "Si♭", "Do", "Re♭", "Mi♭"],
            7: ["Sol", "La", "Si♭", "Do", "Re", "Mi♭", "Fa"],
            9: ["La", "Si", "Do", "Re", "Mi", "Fa", "Sol"],
            11: ["Si", "Do♯", "Re", "Mi", "Fa♯", "Sol", "La"],
        ]
        let kurdi: [Int: [String]] = [
            0: ["Do", "Re♭", "Mi♭", "Fa", "Sol", "La♭", "Si♭"],
            2: ["Re", "Mi♭", "Fa", "Sol", "La", "Si♭", "Do"],
            4: ["Mi", "Fa", "Sol", "La", "Si", "Do", "Re"],
            5: ["Fa", "Sol♭", "La♭", "Si♭", "Do", "Re♭", "Mi♭"],
            7: ["Sol", "La♭", "Si♭", "Do", "Re", "Mi♭", "Fa"],
            9: ["La", "Si♭", "Do", "Re", "Mi", "Fa", "Sol"],
            11: ["Si", "Do", "Re", "Mi", "Fa♯", "Sol", "La"],
        ]
        switch self {
        case .kurdi, .ussak, .kurdilihicazkar:
            return kurdi[tonic] ?? kurdi[0]!
        case .nihavent, .hicaz, .hicazkar:
            return minor[tonic] ?? minor[0]!
        case .major, .minor:
            return []
        }
    }
}

private func makamNoteLabel(_ name: String, octave: Int, step: Double, rootPitchClass: Int) -> String {
    let naturalKomaByName = ["Do": 0, "Re": 9, "Mi": 18, "Fa": 22, "Sol": 31, "La": 40, "Si": 49]
    let naturalKomaByPitchClass = [0: 0, 2: 9, 4: 18, 5: 22, 7: 31, 9: 40, 11: 49]
    let base = ["Sol", "Do", "Re", "Mi", "Fa", "La", "Si"].first(where: { name.hasPrefix($0) }) ?? name
    guard let baseKoma = naturalKomaByName[base], let rootKoma = naturalKomaByPitchClass[rootPitchClass] else {
        return "\(name)\(octave)"
    }
    let naturalStep = (baseKoma - rootKoma + 53) % 53
    let adjustment = Int(step.rounded()) - naturalStep
    guard adjustment != 0 else { return "\(base)\(octave)" }
    let accidental = adjustment < 0 ? "♭" : "♯"
    return "\(base)\(octave) \(accidental)\(abs(adjustment))"
}

func noteName(_ pitchClass: Int) -> String {
    ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"][((pitchClass % 12) + 12) % 12]
}

func approximateNoteName(for frequency: Double, scale: LiveScale) -> String {
    let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
    return "\(noteName(scale.displayedPitchClass(forSoundingPitchClass: midi % 12)))\(midi / 12 - 1)"
}
