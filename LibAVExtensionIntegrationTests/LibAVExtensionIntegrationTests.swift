//
//  LibAVExtensionIntegrationTests.swift
//  LibAVExtensionIntegrationTests
//
//  Created by Anton Marini on 2/24/26.
//

import AVFoundation
import Foundation
import MediaToolbox
import Testing
import VideoToolbox

private enum IntegrationTestError: Error {
    case commandFailed(String)
}

private let registerProfessionalWorkflowReadersAndDecoders: Void = {
    MTRegisterProfessionalVideoWorkflowFormatReaders()
    VTRegisterProfessionalVideoWorkflowVideoDecoders()
}()

private struct FFProbeStream: Decodable {
    var codec_name: String
    var width: Int
    var height: Int
    var avg_frame_rate: String
    var r_frame_rate: String
    var time_base: String
    var has_b_frames: Int?
}

private struct FFProbeFormat: Decodable {
    var duration: String
}

private struct FFProbeStreamEnvelope: Decodable {
    var streams: [FFProbeStream]
    var format: FFProbeFormat
}

private struct FixtureCase {
    var baseName: String
    var ext: String

    var mediaFileName: String { "\(baseName).\(ext)" }
    var streamReferenceFileName: String { "\(baseName).stream.json" }
}

private struct SampleWalkStats {
    var sampleCount: Int = 0
    var keyframeCount: Int = 0
    var nonMonotonicPTSCount: Int = 0
    var invalidDurationCount: Int = 0
    var invalidDTSCount: Int = 0
    var ptsDtsMismatchCount: Int = 0
    var imageBufferCount: Int = 0
    var totalBytes: Int = 0
}

private enum TestPaths {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var fixturesDir: URL {
        repositoryRoot.appendingPathComponent("scripts/TestMedia", isDirectory: true)
    }

    static let fixtureCases: [FixtureCase] = [
        .init(baseName: "baseline_1920_1080_30fps_h264_aac", ext: "mkv"),
        .init(baseName: "baseline_1920_1080_30fps_h264_alli_aac", ext: "mkv"),
        .init(baseName: "baseline_1920_1080_30fps_vp9_opus", ext: "mkv"),
    ]

    // Baby-step demux validation set: all-I H.264 only.
    static let sampleWalkFixtureCases: [FixtureCase] = [
        .init(baseName: "baseline_1920_1080_30fps_h264_alli_aac", ext: "mkv"),
    ]

    static var h264Fixture: URL {
        fixturesDir.appendingPathComponent("baseline_1920_1080_30fps_h264_aac.mkv")
    }

    static var h264FirstGOPReference: URL {
        fixturesDir.appendingPathComponent("baseline_1920_1080_30fps_h264_aac.first_gop.csv")
    }
}

private func requireFile(_ url: URL, hint: String) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw IntegrationTestError.commandFailed("Required file not found at \(url.path). \(hint)")
    }
}

private func parseRational(_ text: String) throws -> Double {
    let parts = text.split(separator: "/")
    guard parts.count == 2,
          let numerator = Double(parts[0]),
          let denominator = Double(parts[1]),
          denominator != 0
    else {
        throw IntegrationTestError.commandFailed("Invalid rational: \(text)")
    }
    return numerator / denominator
}

private func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func loadReferenceEnvelope(_ url: URL) throws -> FFProbeStreamEnvelope {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(FFProbeStreamEnvelope.self, from: data)
}

private func loadAssetVideoContract(_ url: URL) async throws -> (durationSeconds: Double, width: Double, height: Double, frameRate: Float) {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let videoTrack = try #require(videoTracks.first)
    let naturalSize = try await videoTrack.load(.naturalSize)
    let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
    return (duration, naturalSize.width, naturalSize.height, nominalFrameRate)
}

private func walkCompressedSamplesWithAssetReader(_ url: URL, maxSamples: Int) async throws -> SampleWalkStats {
    let asset = AVURLAsset(url: url)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let videoTrack = try #require(videoTracks.first)

    let reader = try AVAssetReader(asset: asset)
    // Use nil output settings for compressed sample passthrough (no decode output conversion).
    let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    output.alwaysCopiesSampleData = false

    guard reader.canAdd(output) else {
        throw IntegrationTestError.commandFailed("AVAssetReader cannot add video track output for \(url.lastPathComponent)")
    }
    reader.add(output)

    guard reader.startReading() else {
        throw reader.error ?? IntegrationTestError.commandFailed("AVAssetReader failed to start for \(url.lastPathComponent)")
    }

    var stats = SampleWalkStats()
    var previousPTS: CMTime?

    while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
        let sampleBytes = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        // Ignore empty boundary buffers; they can carry invalid timing metadata.
        if sampleBytes == 0 {
            continue
        }

        stats.sampleCount += 1
        if stats.sampleCount > maxSamples {
            reader.cancelReading()
            throw IntegrationTestError.commandFailed(
                "Sample walk exceeded maxSamples=\(maxSamples) for \(url.lastPathComponent). Likely cursor cycle/livelock."
            )
        }
        stats.totalBytes += Int(sampleBytes)

        if CMSampleBufferGetImageBuffer(sampleBuffer) != nil {
            stats.imageBufferCount += 1
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let previousPTS, CMTimeCompare(pts, previousPTS) < 0 {
            stats.nonMonotonicPTSCount += 1
        }
        previousPTS = pts

        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        if CMTIME_IS_INVALID(dts) || CMTIME_IS_INDEFINITE(dts) {
            stats.invalidDTSCount += 1
        } else if CMTimeCompare(pts, dts) != 0 {
            stats.ptsDtsMismatchCount += 1
        }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if CMTIME_IS_INVALID(duration) || CMTIME_IS_INDEFINITE(duration) {
            stats.invalidDurationCount += 1
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            if !notSync {
                stats.keyframeCount += 1
            }
        } else {
            // If attachments are missing, count conservatively as sync to avoid false negatives.
            stats.keyframeCount += 1
        }
    }

    if reader.status == .failed {
        throw reader.error ?? IntegrationTestError.commandFailed("AVAssetReader failed while reading \(url.lastPathComponent)")
    }
    if reader.status == .cancelled {
        throw IntegrationTestError.commandFailed("AVAssetReader was cancelled for \(url.lastPathComponent)")
    }

    return stats
}

@Suite("MediaExtension Fixture + Contract Tests")
struct LibAVExtensionIntegrationTests {
   
    init() {
        _ = registerProfessionalWorkflowReadersAndDecoders
    }

    @Test("Fixture stream references exist for full matrix")
    func fixtureReferenceMatrixExists() throws {
        for fixture in TestPaths.fixtureCases {
            let mediaURL = TestPaths.fixturesDir.appendingPathComponent(fixture.mediaFileName)
            let refURL = TestPaths.fixturesDir.appendingPathComponent(fixture.streamReferenceFileName)
            try requireFile(mediaURL, hint: "Generate test media first.")
            try requireFile(refURL, hint: "Run scripts/TestMedia/generate_fixture_reference_data.sh")

            let envelope = try loadReferenceEnvelope(refURL)
            let stream = try #require(envelope.streams.first)
            #expect(stream.width == 1920)
            #expect(stream.height == 1080)
            #expect(stream.avg_frame_rate == "30/1")
            #expect((envelope.format.duration as NSString).doubleValue > 0.0)
        }
    }

    @Test("Fixture first GOP shape matches expected frame ordering")
    func fixtureFirstGOPShape() throws {
        let fixtureURL = TestPaths.h264Fixture
        let referenceURL = TestPaths.h264FirstGOPReference
        try requireFile(fixtureURL, hint: "Generate test media first.")
        try requireFile(referenceURL, hint: "Run scripts/TestMedia/generate_fixture_reference_data.sh")

        let rows = try String(contentsOf: referenceURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        #expect(rows.count == 5)

        let first = rows[0].split(separator: ",")
        let second = rows[1].split(separator: ",")
        let third = rows[2].split(separator: ",")
        let fourth = rows[3].split(separator: ",")
        let fifth = rows[4].split(separator: ",")

        #expect(first.count >= 3)
        #expect(first[0] == "1")
        #expect(first[2] == "I")

        #expect(second.count >= 3)
        #expect(second[0] == "0")
        #expect(second[2] == "B")

        #expect(third.count >= 3)
        #expect(third[0] == "0")
        #expect(third[2] == "B")

        #expect(fourth.count >= 3)
        #expect(fourth[0] == "0")
        #expect(fourth[2] == "B")

        #expect(fifth.count >= 3)
        #expect(fifth[0] == "0")
        #expect(fifth[2] == "P")
    }

    @Test("AVFoundation fixture matrix contracts through extension")
    func avfoundationFixtureMatrixContracts() async throws {
        for fixture in TestPaths.fixtureCases {
            let mediaURL = TestPaths.fixturesDir.appendingPathComponent(fixture.mediaFileName)
            let refURL = TestPaths.fixturesDir.appendingPathComponent(fixture.streamReferenceFileName)
            try requireFile(mediaURL, hint: "Generate test media first.")
            try requireFile(refURL, hint: "Run scripts/TestMedia/generate_fixture_reference_data.sh")

            let reference = try loadReferenceEnvelope(refURL)
            let refStream = try #require(reference.streams.first)

            let contract: (durationSeconds: Double, width: Double, height: Double, frameRate: Float)
            do {
                contract = try await loadAssetVideoContract(mediaURL)
            } catch {
                throw IntegrationTestError.commandFailed(
                    "AVFoundation contract failed for \(fixture.mediaFileName): \(error)"
                )
            }
            #expect(approxEqual(contract.width, Double(refStream.width), tolerance: 0.5))
            #expect(approxEqual(contract.height, Double(refStream.height), tolerance: 0.5))

            let refFPS = try parseRational(refStream.avg_frame_rate)
            #expect(approxEqual(Double(contract.frameRate), refFPS, tolerance: 1.0))

            // ffprobe duration is authoritative for fixture creation, allow modest mux/host tolerance.
            let refDuration = (reference.format.duration as NSString).doubleValue
            #expect(approxEqual(contract.durationSeconds, refDuration, tolerance: 0.25))
        }
    }

    @Test("AVAssetReader sample walk validates mux step-by-step sample flow through extension")
    func avassetReaderSampleWalkMatrix() async throws {
        for fixture in TestPaths.sampleWalkFixtureCases {
            let mediaURL = TestPaths.fixturesDir.appendingPathComponent(fixture.mediaFileName)
            let refURL = TestPaths.fixturesDir.appendingPathComponent(fixture.streamReferenceFileName)
            try requireFile(mediaURL, hint: "Generate test media first.")
            try requireFile(refURL, hint: "Run scripts/TestMedia/generate_fixture_reference_data.sh")

            let reference = try loadReferenceEnvelope(refURL)
            let refStream = try #require(reference.streams.first)
            let refFPS = try parseRational(refStream.avg_frame_rate)
            let refDuration = (reference.format.duration as NSString).doubleValue
            let expectedFrameCount = Int((refDuration * refFPS).rounded())
            let maxSamples = max(expectedFrameCount * 3, expectedFrameCount + 50)

            let stats: SampleWalkStats
            do {
                stats = try await walkCompressedSamplesWithAssetReader(mediaURL, maxSamples: maxSamples)
            } catch {
                throw IntegrationTestError.commandFailed(
                    "Sample-walk failed for \(fixture.mediaFileName): \(error)"
                )
            }
            #expect(stats.sampleCount > 0)
            #expect(stats.totalBytes > 0)
            #expect(stats.nonMonotonicPTSCount == 0)
            #expect(stats.invalidDurationCount == 0)
            #expect(stats.invalidDTSCount == 0)
            #expect(stats.ptsDtsMismatchCount == 0)
            #expect(stats.keyframeCount > 0)

            // In compressed sample mode, image buffers should not be produced.
            #expect(stats.imageBufferCount == 0)

            #expect(abs(stats.sampleCount - expectedFrameCount) <= 3)
        }
    }
}
