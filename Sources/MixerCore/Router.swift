import Foundation
import CoreAudio
import AudioToolbox
import os

/// Routes one process's audio to a chosen output device using a Core Audio
/// process tap (macOS 14.2+), with a decoupled capture→playback path:
///
///   [tap] --capture aggregate--> IOProc A --> ring buffer --> IOProc B --> [DAC]
///
/// The DAC is opened DIRECTLY (its normal IO path), never as a sub-device of an
/// aggregate — combining a hardware DAC into the tap aggregate proved fragile
/// (triggered the DAC's USB static). The ring buffer absorbs jitter/drift between
/// the tap clock and the DAC clock.
public final class ProcessAudioRouter {
    public var verbose = false
    private func log(_ s: @autoclosure () -> String) { if verbose { print(s()) } }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var captureAggID = AudioObjectID(kAudioObjectUnknown)
    private var captureProcID: AudioDeviceIOProcID?
    private var dacID = AudioObjectID(kAudioObjectUnknown)
    private var dacProcID: AudioDeviceIOProcID?
    private let tapUUID = UUID()
    private var meterTimer: DispatchSourceTimer?

    private var ring: AudioRingBuffer?
    private var prerollFrames = 0
    private var maxFillFrames = 0  // high-water mark for drift compensation
    private var draining = false   // consumer state: false until buffer pre-fills
    private var lastFrame: [Float] = []

    // Meter values are shared by realtime callbacks and the UI/timer.
    private let meterLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    // Metering (written from realtime callbacks, read/reset on main thread).
    fileprivate var meterOutPeak: Float = 0
    fileprivate var meterUnderflows = 0
    fileprivate var meterOverflows = 0
    fileprivate var meterBadSamples = 0

    private func updateMeter(_ body: () -> Void) {
        os_unfair_lock_lock(meterLock)
        body()
        os_unfair_lock_unlock(meterLock)
    }

    private func takeMeter() -> (peak: Float, underflows: Int, overflows: Int, badSamples: Int) {
        os_unfair_lock_lock(meterLock)
        let result = (meterOutPeak, meterUnderflows, meterOverflows, meterBadSamples)
        meterOutPeak = 0
        meterUnderflows = 0
        meterOverflows = 0
        meterBadSamples = 0
        os_unfair_lock_unlock(meterLock)
        return result
    }

    private func describe(_ f: AudioStreamBasicDescription) -> String {
        let flags = f.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        return String(format: "%.0f Hz, %u ch, %u-bit %@, %u bytes/frame",
                      f.mSampleRate, f.mChannelsPerFrame, f.mBitsPerChannel,
                      isFloat ? "float" : "int", f.mBytesPerFrame)
    }

    public enum RouterError: Error, CustomStringConvertible {
        case processNotFound(String)
        case deviceNotFound(String)
        case tapCreateFailed(OSStatus)
        case aggregateCreateFailed(OSStatus)
        case ioProcFailed(String, OSStatus)
        case startFailed(String, OSStatus)
        case unsupportedFormat(String)
        case alreadyRunning

        public var description: String {
            switch self {
            case .processNotFound(let b): return "No running audio process matching '\(b)'. Is the app playing / open?"
            case .deviceNotFound(let d): return "No output device matching '\(d)'."
            case .tapCreateFailed(let s): return "AudioHardwareCreateProcessTap failed: \(s) (check Audio Capture permission)."
            case .aggregateCreateFailed(let s): return "AudioHardwareCreateAggregateDevice failed: \(s)."
            case .ioProcFailed(let w, let s): return "\(w) IOProc create failed: \(s)."
            case .startFailed(let w, let s): return "\(w) start failed: \(s)."
            case .unsupportedFormat(let f): return "Unsupported audio format: \(f)."
            case .alreadyRunning: return "This router is already running."
            }
        }
    }

    private func validate(_ format: AudioStreamBasicDescription, label: String) throws {
        let flags = format.mFormatFlags
        let valid = format.mFormatID == kAudioFormatLinearPCM &&
            (flags & kAudioFormatFlagIsFloat) != 0 &&
            (flags & kAudioFormatFlagIsPacked) != 0 &&
            (flags & kAudioFormatFlagIsNonInterleaved) == 0 &&
            format.mBitsPerChannel == 32 &&
            format.mBytesPerFrame == format.mChannelsPerFrame * 4 &&
            format.mBytesPerPacket == format.mBytesPerFrame &&
            format.mChannelsPerFrame > 0 &&
            format.mSampleRate.isFinite && format.mSampleRate > 0
        guard valid else {
            throw RouterError.unsupportedFormat("\(label): \(describe(format)); expected interleaved 32-bit Float32 PCM")
        }
    }

    /// Start routing an already-resolved process object to an output device.
    public func start(processObjectID: AudioObjectID, deviceID: AudioDeviceID, deviceName: String = "") throws {
        guard tapID == kAudioObjectUnknown, captureAggID == kAudioObjectUnknown,
              captureProcID == nil, dacProcID == nil else { throw RouterError.alreadyRunning }
        var started = false
        defer { if !started { stop() } }
        dacID = deviceID

        log("→ Tapping process \(processObjectID) → \(deviceName.isEmpty ? String(deviceID) : deviceName) [direct output]")

        // 2. Process tap, muted at source.
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        desc.uuid = tapUUID
        desc.name = "MixerApp Tap"
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.muted
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else { throw RouterError.tapCreateFailed(status) }

        guard let tapFormat = CA.format(tapID, kAudioTapPropertyFormat) else {
            throw RouterError.unsupportedFormat("tap format unavailable")
        }
        try validate(tapFormat, label: "tap")
        log("   tap format:  \(describe(tapFormat))")
        let channels = Int(tapFormat.mChannelsPerFrame)
        let sampleRate = tapFormat.mSampleRate
        guard let dacFormat = CA.format(deviceID, kAudioDevicePropertyStreamFormat,
                                        scope: kAudioObjectPropertyScopeOutput) else {
            throw RouterError.unsupportedFormat("output device format unavailable")
        }
        try validate(dacFormat, label: "output")
        guard dacFormat.mChannelsPerFrame == tapFormat.mChannelsPerFrame else {
            throw RouterError.unsupportedFormat("tap has \(tapFormat.mChannelsPerFrame) channels but output has \(dacFormat.mChannelsPerFrame)")
        }
        guard abs(dacFormat.mSampleRate - sampleRate) < 0.5 else {
            throw RouterError.unsupportedFormat("tap is \(sampleRate) Hz but output is \(dacFormat.mSampleRate) Hz")
        }

        // 3. Capture aggregate: contains ONLY the tap (no hardware sub-device).
        let aggUID = "com.mixerpoc.capture.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MixerPOC Capture",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapDriftCompensationKey as String: true,
                 kAudioSubTapUIDKey as String: tapUUID.uuidString]
            ]
        ]
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &captureAggID)
        guard status == noErr, captureAggID != kAudioObjectUnknown else { throw RouterError.aggregateCreateFailed(status) }

        // 4. Ring buffer: ~1s capacity, start draining once ~150ms buffered.
        //    The high-water mark keeps long-session clock drift bounded.
        let capacityFrames = Int(sampleRate * 1.0)
        guard capacityFrames > 0 else { throw RouterError.unsupportedFormat("invalid buffer capacity") }
        let ring = AudioRingBuffer(capacityFrames: capacityFrames, channels: channels)
        self.ring = ring
        prerollFrames = Int(sampleRate * 0.15)
        maxFillFrames = Int(sampleRate * 0.45)
        draining = false
        lastFrame = Array(repeating: 0, count: channels)

        // 5. Capture IOProc: tap input → ring buffer.
        status = AudioDeviceCreateIOProcIDWithBlock(&captureProcID, captureAggID, nil) { [weak self] (_, inInputData, _, _, _) in
            guard let self = self, let ring = self.ring else { return }
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard input.count == 1, input[0].mNumberChannels == UInt32(ring.channels),
                  let data = input[0].mData else { return }
            let frames = Int(input[0].mDataByteSize) / (ring.channels * MemoryLayout<Float>.size)
            let dropped = ring.write(data.assumingMemoryBound(to: Float.self), frames: frames)
            if dropped > 0 { self.updateMeter { self.meterOverflows += dropped } }
        }
        guard status == noErr, let capProc = captureProcID else { throw RouterError.ioProcFailed("capture", status) }

        // 6. DAC IOProc (direct): ring buffer → DAC output, with clamp + metering.
        status = AudioDeviceCreateIOProcIDWithBlock(&dacProcID, dacID, nil) { [weak self] (_, _, _, outOutputData, _) in
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buf in output { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
            guard let self = self, let ring = self.ring,
                  output.count == 1, output[0].mNumberChannels == UInt32(ring.channels),
                  let dst = output[0].mData else { return }

            let frames = Int(output[0].mDataByteSize) / (ring.channels * MemoryLayout<Float>.size)
            guard frames > 0 else { return }
            let fp = dst.assumingMemoryBound(to: Float.self)

            // Pre-roll: stay silent until the buffer has built up a safety margin,
            // and re-buffer if we ever drain empty (avoids continuous crackle).
            if !self.draining {
                if ring.fillFrames >= self.prerollFrames { self.draining = true }
                else { return }   // output already zeroed = silence
            }

            let fillBeforeRead = ring.fillFrames
            let lowWater = ring.capacityFrames / 5
            let repeatFrame = fillBeforeRead <= lowWater && frames > 1
            let framesToRead = repeatFrame ? frames - 1 : frames
            let underflow = ring.read(fp, frames: framesToRead)
            if repeatFrame && underflow == 0 {
                for c in 0..<ring.channels { fp[(frames - 1) * ring.channels + c] = self.lastFrame[c] }
            }
            // Gradually discard one oldest frame while above the 450 ms
            // high-water mark. This bounds latency without a large audible skip.
            if fillBeforeRead > self.maxFillFrames && underflow == 0 {
                ring.discard(frames: 1)
                self.updateMeter { self.meterOverflows += 1 }
            }
            if underflow > 0 {
                self.updateMeter { self.meterUnderflows += underflow }
                if ring.fillFrames == 0 { self.draining = false }   // re-buffer
            }

            // Clamp: never send out-of-range floats to the DAC.
            var peak: Float = 0
            let n = frames * ring.channels
            for j in 0..<n {
                var v = fp[j]
                if !v.isFinite { v = 0; self.updateMeter { self.meterBadSamples += 1 } }
                let a = abs(v); if a > peak { peak = a }
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                fp[j] = v
            }
            for c in 0..<ring.channels { self.lastFrame[c] = fp[(frames - 1) * ring.channels + c] }
            self.updateMeter { if peak > self.meterOutPeak { self.meterOutPeak = peak } }
        }
        guard status == noErr, let dacProc = dacProcID else { throw RouterError.ioProcFailed("DAC", status) }

        // 7. Start capture first (fill the buffer), then the DAC.
        status = AudioDeviceStart(captureAggID, capProc)
        guard status == noErr else { throw RouterError.startFailed("capture", status) }
        status = AudioDeviceStart(dacID, dacProc)
        guard status == noErr else { throw RouterError.startFailed("DAC", status) }

        // Meter (verbose/CLI only — keeps the app quiet).
        if verbose {
            let sr = sampleRate
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                guard let self = self, let ring = self.ring else { return }
                let fillMs = Double(ring.fillFrames) / sr * 1000
                let meter = self.takeMeter()
                let flag = (meter.underflows > 0 || meter.overflows > 0 || meter.badSamples > 0) ? "  <-- GLITCH" : ""
                print(String(format: "   meter: out peak %.3f  buffer %.0f ms  underflow=%d overflow=%d bad=%d%@",
                             meter.peak, fillMs, meter.underflows, meter.overflows, meter.badSamples, flag))
            }
            timer.resume()
            meterTimer = timer
        }

        started = true
        log("✓ Routing live (decoupled).")
    }

    public init() {
        meterLock.initialize(to: os_unfair_lock())
    }

    deinit {
        stop()
        meterLock.deinitialize(count: 1)
        meterLock.deallocate()
    }

    /// Peak output level (0…1) since the last call, then resets. Drives the UI
    /// activity meter. Access is synchronized with the realtime callback.
    public func readLevel() -> Float {
        takeMeter().peak
    }

    public func stop() {
        meterTimer?.cancel(); meterTimer = nil
        if let p = dacProcID, dacID != kAudioObjectUnknown {
            AudioDeviceStop(dacID, p)
            AudioDeviceDestroyIOProcID(dacID, p)
            dacProcID = nil
        }
        if let p = captureProcID, captureAggID != kAudioObjectUnknown {
            AudioDeviceStop(captureAggID, p)
            AudioDeviceDestroyIOProcID(captureAggID, p)
            captureProcID = nil
        }
        if captureAggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(captureAggID)
            captureAggID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        dacID = kAudioObjectUnknown
        ring = nil
        lastFrame.removeAll(keepingCapacity: false)
        draining = false
    }
}
