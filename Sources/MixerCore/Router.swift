import Foundation
import CoreAudio
import AudioToolbox

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
    private var draining = false   // consumer state: false until buffer pre-fills

    // Metering (written from realtime callbacks, read/reset on main thread).
    fileprivate var meterOutPeak: Float = 0
    fileprivate var meterUnderflows = 0
    fileprivate var meterOverflows = 0
    fileprivate var meterBadSamples = 0

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

        public var description: String {
            switch self {
            case .processNotFound(let b): return "No running audio process matching '\(b)'. Is the app playing / open?"
            case .deviceNotFound(let d): return "No output device matching '\(d)'."
            case .tapCreateFailed(let s): return "AudioHardwareCreateProcessTap failed: \(s) (check Audio Capture permission)."
            case .aggregateCreateFailed(let s): return "AudioHardwareCreateAggregateDevice failed: \(s)."
            case .ioProcFailed(let w, let s): return "\(w) IOProc create failed: \(s)."
            case .startFailed(let w, let s): return "\(w) start failed: \(s)."
            }
        }
    }

    /// Start routing an already-resolved process object to an output device.
    public func start(processObjectID: AudioObjectID, deviceID: AudioDeviceID, deviceName: String = "") throws {
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

        let tapFormat = CA.format(tapID, kAudioTapPropertyFormat)
        if let tf = tapFormat { log("   tap format:  \(describe(tf))") }
        let channels = Int(tapFormat?.mChannelsPerFrame ?? 2)
        let sampleRate = tapFormat?.mSampleRate ?? 48000

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

        // 4. Ring buffer: ~500ms capacity, start draining once ~120ms buffered.
        let ring = AudioRingBuffer(capacityFrames: Int(sampleRate * 0.5), channels: channels)
        self.ring = ring
        prerollFrames = Int(sampleRate * 0.12)
        draining = false

        // 5. Capture IOProc: tap input → ring buffer.
        status = AudioDeviceCreateIOProcIDWithBlock(&captureProcID, captureAggID, nil) { [weak self] (_, inInputData, _, _, _) in
            guard let self = self, let ring = self.ring else { return }
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard input.count > 0, let data = input[0].mData else { return }
            let frames = Int(input[0].mDataByteSize) / (ring.channels * MemoryLayout<Float>.size)
            let dropped = ring.write(data.assumingMemoryBound(to: Float.self), frames: frames)
            if dropped > 0 { self.meterOverflows += dropped }
        }
        guard status == noErr, let capProc = captureProcID else { throw RouterError.ioProcFailed("capture", status) }

        // 6. DAC IOProc (direct): ring buffer → DAC output, with clamp + metering.
        status = AudioDeviceCreateIOProcIDWithBlock(&dacProcID, dacID, nil) { [weak self] (_, _, _, outOutputData, _) in
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buf in output { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
            guard let self = self, let ring = self.ring,
                  output.count > 0, let dst = output[0].mData else { return }

            let frames = Int(output[0].mDataByteSize) / (ring.channels * MemoryLayout<Float>.size)
            let fp = dst.assumingMemoryBound(to: Float.self)

            // Pre-roll: stay silent until the buffer has built up a safety margin,
            // and re-buffer if we ever drain empty (avoids continuous crackle).
            if !self.draining {
                if ring.fillFrames >= self.prerollFrames { self.draining = true }
                else { return }   // output already zeroed = silence
            }

            let underflow = ring.read(fp, frames: frames)
            if underflow > 0 {
                self.meterUnderflows += underflow
                if ring.fillFrames == 0 { self.draining = false }   // re-buffer
            }

            // Clamp: never send out-of-range floats to the DAC.
            var peak: Float = 0
            let n = frames * ring.channels
            for j in 0..<n {
                var v = fp[j]
                if !v.isFinite { v = 0; self.meterBadSamples += 1 }
                let a = abs(v); if a > peak { peak = a }
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                fp[j] = v
            }
            if peak > self.meterOutPeak { self.meterOutPeak = peak }
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
                let peak = self.meterOutPeak
                let flag = (self.meterUnderflows > 0 || self.meterOverflows > 0 || self.meterBadSamples > 0) ? "  <-- GLITCH" : ""
                print(String(format: "   meter: out peak %.3f  buffer %.0f ms  underflow=%d overflow=%d bad=%d%@",
                             peak, fillMs, self.meterUnderflows, self.meterOverflows, self.meterBadSamples, flag))
                self.meterOutPeak = 0
                self.meterUnderflows = 0
                self.meterOverflows = 0
                self.meterBadSamples = 0
            }
            timer.resume()
            meterTimer = timer
        }

        log("✓ Routing live (decoupled).")
    }

    public init() {}

    /// Peak output level (0…1) since the last call, then resets. Drives the UI
    /// activity meter. Written from the realtime callback; a benign race for a meter.
    public func readLevel() -> Float {
        let v = meterOutPeak
        meterOutPeak = 0
        return v
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
    }
}
