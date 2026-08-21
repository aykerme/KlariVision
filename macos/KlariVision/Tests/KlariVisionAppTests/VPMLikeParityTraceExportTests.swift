import Foundation
import XCTest
@testable import KlariVisionApp

private struct VPMLikeParityJob: Codable {
    let input: String
    let output: String
    let sampleRate: Double
    let windowSize: Int
    let hopSize: Int
    let minimumRMS: Double
}

final class VPMLikeParityTraceExportTests: XCTestCase {
    func testExportShippedSwiftTraceWhenRequested() throws {
        guard let manifestPath = ProcessInfo.processInfo.environment["KLARIVISION_VPM_PARITY_JOBS"] else {
            throw XCTSkip("Set KLARIVISION_VPM_PARITY_JOBS to run the cross-language trace exporter")
        }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let jobs = try JSONDecoder().decode(
            [VPMLikeParityJob].self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertFalse(jobs.isEmpty)

        for job in jobs {
            let data = try Data(contentsOf: URL(fileURLWithPath: job.input))
            XCTAssertEqual(data.count % MemoryLayout<Float>.stride, 0)
            let samples = data.withUnsafeBytes { rawBuffer -> [Float] in
                Array(rawBuffer.bindMemory(to: Float.self))
            }
            let trace = shippedSwiftVPMLikeParityTrace(
                samples: samples,
                sampleRate: job.sampleRate,
                windowSize: job.windowSize,
                hopSize: job.hopSize,
                minimumRMS: job.minimumRMS
            )
            let encoded = try JSONEncoder().encode(trace)
            try encoded.write(to: URL(fileURLWithPath: job.output), options: .atomic)
        }
    }
}
