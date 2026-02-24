# MediaExtension Validation Plan

## Purpose
Establish a repeatable validation workflow for the MediaExtension plugin so we can prove each API assumption, isolate regressions quickly, and avoid "fix by guesswork".

## Current API Contract Observations (from `MEFormatReader.h`)
1. `generateSampleCursorAtPresentationTimeStamp` should return the last sample with `PTS <= requestedPTS`, or the first sample if none exists.
2. `stepInDecodeOrderByCount` moves in decode order, not presentation order. With B-frames, decode stepping may jump in PTS.
3. `decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource` is a remaining playable range from current DTS, not an absolute timeline endpoint.
4. Preferred sample delivery path is `sampleLocation`/`chunkDetails` so CoreMedia can optimize I/O.
5. `loadSampleBufferContainingSamplesToEndCursor` is required if sample locations cannot be provided.
6. `requestedPTS={+inf}` should resolve to a valid near-end cursor and should not reset playback flow back to start.

## Validation Pillars
1. Well-formed deterministic test media.
2. AVFoundation-driven integration tests that exercise the extension as the host sees it.

## Test Matrix

### 1) Fixture Correctness (Ground Truth)
- Generate deterministic fixtures for each target container/codec combination.
- Build `ffprobe` truth artifacts:
  - stream metadata (codec, time base, rates, dimensions)
  - frame table (PTS/DTS/keyframe/pict_type)
  - packet table (offset/size/flags)
- Pass criteria:
  - stable metadata and frame/packet ordering across runs.

### 2) File + Track Info Contract
- Load asset through AVFoundation and extension.
- Validate:
  - file duration
  - track count/types
  - format description fields (`avcC`, dimensions, media subtype)
  - nominal frame rate and timescale
- Pass criteria:
  - values match fixture truth within tolerance.

### 3) Cursor Creation Contract
- Request cursors at:
  - `0`
  - exact frame boundary
  - between-frame timestamp
  - mid timeline
  - `+inf`
- Validate:
  - returned cursor exists
  - returned `PTS <= requestedPTS` and is nearest expected sample
  - `+inf` resolves to near-end (never fallback-to-zero unless true empty media)
- Pass criteria:
  - deterministic mapping to expected frame indices.

### 4) Cursor Stepping Contract
- Validate:
  - decode-order stepping `+1/-1`
  - presentation-order stepping `+1/-1`
  - boundary pin behavior (start/end)
  - `actualStepCount` semantics
- Pass criteria:
  - observed cursor timeline transitions match fixture truth.

### 5) Sample Data Path Contract
- Validate both modes:
  - location mode (`sampleLocation` + `chunkDetails`)
  - direct buffer mode (`loadSampleBuffer...`)
- Ensure:
  - no nil sample buffer on non-error
  - no location-not-available for contiguous sample cases
  - end-cursor behavior does not force reset-to-zero
- Pass criteria:
  - host can continuously fetch samples without flow reset.

### 6) Playback + Seek Integration (AVFoundation)
- Integration scenarios:
  - play from start
  - seek to mid
  - seek near end
  - seek back to zero
- Validate:
  - displayed frame timestamps progress in expected order during playback
  - no stalls on frame 1/frame 5 pattern
  - no forced restart loops from `+inf` requests
- Pass criteria:
  - smooth progression across at least N seconds with no reset loops.

### 7) Pixel Correctness (Reference Compare)
- Decode sampled timestamps via AVFoundation pipeline.
- Decode corresponding reference frames via FFmpeg.
- Compare via absolute difference (mean/max channel thresholds).
- Pass criteria:
  - diffs under agreed thresholds at tested timestamps.

### 8) Stability + Stress
- Repeated open/close cycles.
- Randomized seek/play stress.
- Long playback run.
- Pass criteria:
  - no crashes, no deadlocks, no increasing failure rate.

## Execution Order (Recommended)
1. Fixture truth generation.
2. File/track contract tests.
3. Cursor creation tests (`+inf` included).
4. Cursor stepping tests.
5. Sample data path tests.
6. Playback/seek integration tests.
7. Pixel diff tests.
8. Stress tests.

## Immediate Next Focus
1. Eliminate `+inf -> fallback-to-zero` behavior.
2. Confirm `decodeTimeOfLastSampleReachable...` semantics against runtime behavior.
3. Lock one stable sample data path first (prefer location path for contiguous samples), then keep direct buffer path as fallback.

