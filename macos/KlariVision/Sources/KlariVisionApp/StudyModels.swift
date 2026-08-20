// KlariVision macOS — Dinleme modu için saf veri modelleri ve JSON çözümleme.
// Ayar taslağını doğrular, yan `.vamp.json` karelerini güvenli modele dönüştürür.
// Medya oynatmaz ve UI state'i sahiplenmez; bu ayrım bağımsız test sağlar.

import Foundation
import SwiftUI

struct StudySettingsDraft: Codable, Identifiable {
    let id = UUID()
    var scale: String
    var tonic: Int
    var countdown: Int
    var intervals: [String: [Int]]
    var graphAppearance: GraphAppearance

    enum CodingKeys: String, CodingKey {
        case scale, tonic, countdown, intervals, graphAppearance
    }

    init?(values: [String: Any]) {
        guard let scale = values["scale"] as? String,
              LiveScale(rawValue: scale) != nil,
              let tonic = (values["tonic"] as? NSNumber)?.intValue,
              [0, 2, 4, 5, 7, 9, 11].contains(tonic),
              let countdown = (values["countdown"] as? NSNumber)?.intValue,
              let rawIntervals = values["intervals"] as? [String: [NSNumber]] else { return nil }
        let intervals = rawIntervals.mapValues { $0.map(\.intValue) }
        guard LiveMakamIntervals.isValid(intervals) else { return nil }
        self.scale = scale
        self.tonic = tonic
        self.countdown = min(60, max(0, countdown))
        self.intervals = intervals
        self.graphAppearance = GraphAppearance(
            pitchHex: (values["graphAppearance"] as? [String: Any])?["pitchHex"] as? String ?? GraphAppearance.defaultPitchHex,
            noteGuideHex: (values["graphAppearance"] as? [String: Any])?["noteGuideHex"] as? String ?? GraphAppearance.defaultNoteGuideHex
        )
    }
}

struct StudyPitchPoint: Equatable {
    let time: TimeInterval
    let frequency: Double
}

struct StudyPitchTrack: Equatable {
    private struct Payload: Decodable {
        struct Frame: Decodable {
            let timeSeconds: Double
            let frequencyHz: Double?
            let voiced: Bool?
            let confidence: Double?

            enum CodingKeys: String, CodingKey {
                case timeSeconds = "time_seconds"
                case frequencyHz = "frequency_hz"
                case voiced, confidence
            }
        }

        let frames: [Frame]
    }

    /// Older self-contained viewers store their already prepared curve in the
    /// HTML. Keeping this fallback means a missing sidecar never disables the
    /// media controls for an otherwise valid saved study.
    private struct EmbeddedFrame: Decodable {
        let time: Double
        let frequency: Double

        enum CodingKeys: String, CodingKey {
            case time = "t"
            case frequency = "hz"
        }
    }

    static let minimumConfidence = 0.20
    let points: [StudyPitchPoint]

    static func load(viewer: URL) throws -> Self {
        for sidecar in sidecarCandidates(for: viewer) {
            if let payload = try? JSONDecoder().decode(Payload.self, from: Data(contentsOf: sidecar)) {
                return Self(points: prepareDisplayPoints(payload.frames))
            }
        }

        let html = try String(contentsOf: viewer, encoding: .utf8)
        if let points = embeddedPoints(in: html) {
            return Self(points: points.sorted { $0.time < $1.time })
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func prepareDisplayPoints(from data: Data) throws -> [StudyPitchPoint] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return prepareDisplayPoints(payload.frames)
    }

    private static func prepareDisplayPoints(_ rawFrames: [Payload.Frame]) -> [StudyPitchPoint] {
        let candidates = rawFrames.compactMap { frame -> StudyPitchPoint? in
            guard frame.voiced == true,
                  let frequency = frame.frequencyHz,
                  frequency >= 80,
                  (frame.confidence ?? 0) >= minimumConfidence else { return nil }
            return StudyPitchPoint(time: frame.timeSeconds, frequency: frequency)
        }

        let kept = candidates.enumerated().compactMap { index, frame -> StudyPitchPoint? in
            guard index > 0, index < candidates.count - 1 else { return frame }
            let before = candidates[index - 1]
            let after = candidates[index + 1]
            let nearby = after.time - before.time <= 0.025
            let jump = abs(cents(frame.frequency) - cents(before.frequency)) > 110
            let returns = abs(cents(after.frequency) - cents(before.frequency)) < 35
            return nearby && jump && returns ? nil : frame
        }

        return kept.indices.map { index in
            let lower = max(0, index - 1)
            let upper = min(kept.count, index + 2)
            let neighbourhood = Array(kept[lower..<upper])
            guard neighbourhood.count == 3,
                  neighbourhood[2].time - neighbourhood[0].time <= 0.025 else {
                return kept[index]
            }
            let ordered = neighbourhood.map { cents($0.frequency) }.sorted()
            return StudyPitchPoint(
                time: kept[index].time,
                frequency: 440 * pow(2, ordered[1] / 1_200)
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func sidecarCandidates(for viewer: URL) -> [URL] {
        let exact = viewer.deletingPathExtension().appendingPathExtension("vamp.json")
        let stem = viewer.deletingPathExtension().lastPathComponent + "."
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: viewer.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let related = siblings
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(stem) }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        return related.reduce(into: [exact]) { candidates, candidate in
            if candidate != exact { candidates.append(candidate) }
        }
    }

    private static func embeddedPoints(in html: String) -> [StudyPitchPoint]? {
        guard let declaration = html.range(of: "const frames=") else { return nil }
        let start = declaration.upperBound
        guard let end = html[start...].firstIndex(of: ";"),
              let frames = try? JSONDecoder().decode([EmbeddedFrame].self, from: Data(html[start..<end].utf8)) else {
            return nil
        }
        let points = frames.compactMap { frame -> StudyPitchPoint? in
            guard frame.time.isFinite, frame.frequency.isFinite, frame.frequency > 0 else { return nil }
            return StudyPitchPoint(time: frame.time, frequency: frame.frequency)
        }
        return points.isEmpty ? nil : points
    }

    private static func cents(_ frequency: Double) -> Double {
        1_200 * log2(frequency / 440)
    }
}
