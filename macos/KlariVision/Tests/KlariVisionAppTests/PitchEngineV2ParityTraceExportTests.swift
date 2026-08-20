import Foundation
import XCTest
@testable import KlariVisionApp

private struct PitchEngineV2ParityJob: Codable {
    let input: String
    let output: String
    let sampleRate: Double
    let windowSize: Int
    let hopSize: Int
    let minimumRMS: Double
    let exportDiagnostics: Bool?
}

final class PitchEngineV2ParityTraceExportTests: XCTestCase {
    func testExportShippedSwiftTraceWhenRequested() throws {
        guard let manifestPath = ProcessInfo.processInfo.environment["KLARIVISION_V2_PARITY_JOBS"] else {
            throw XCTSkip("Set KLARIVISION_V2_PARITY_JOBS to run the Python/Swift trace exporter")
        }
        let jobs = try JSONDecoder().decode(
            [PitchEngineV2ParityJob].self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
        )
        XCTAssertFalse(jobs.isEmpty)

        for job in jobs {
            let data = try Data(contentsOf: URL(fileURLWithPath: job.input))
            XCTAssertEqual(data.count % MemoryLayout<Float>.stride, 0)
            let samples = data.withUnsafeBytes { rawBuffer -> [Float] in
                Array(rawBuffer.bindMemory(to: Float.self))
            }
            let trace = shippedSwiftPitchEngineV2ParityTrace(
                samples: samples,
                sampleRate: job.sampleRate,
                windowSize: job.windowSize,
                hopSize: job.hopSize,
                minimumRMS: job.minimumRMS
            )
            try JSONEncoder().encode(trace).write(
                to: URL(fileURLWithPath: job.output), options: .atomic
            )
            if job.exportDiagnostics == true {
                let diagnostics = shippedSwiftPitchEngineV2CandidateDiagnostics(
                    samples: samples,
                    sampleRate: job.sampleRate,
                    windowSize: job.windowSize,
                    hopSize: job.hopSize,
                    minimumRMS: job.minimumRMS
                )
                try JSONEncoder().encode(diagnostics).write(
                    to: URL(fileURLWithPath: job.output + ".diagnostics.json"), options: .atomic
                )
            }
        }
    }
}
