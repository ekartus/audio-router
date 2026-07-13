import Foundation
import os

/// Single-producer / single-consumer ring buffer of interleaved float frames.
/// The capture (tap) callback is the producer; the DAC callback is the consumer.
/// They run on two independent realtime clocks, so this buffer absorbs the jitter
/// and small drift between them.
///
/// Indices are monotonic frame counters. Only tiny index reads/writes are guarded
/// by a spin-lock; the actual sample copies happen outside the lock on disjoint
/// regions (safe because it's strictly one producer and one consumer).
final class AudioRingBuffer {
    let channels: Int
    let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var writeFrame = 0
    private var readFrame = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * channels)
        self.storage.initialize(repeating: 0, count: capacityFrames * channels)
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    private func indices() -> (read: Int, write: Int) {
        os_unfair_lock_lock(lock)
        let r = readFrame, w = writeFrame
        os_unfair_lock_unlock(lock)
        return (r, w)
    }

    /// Frames currently buffered.
    var fillFrames: Int {
        let (r, w) = indices()
        return w - r
    }

    /// Producer: copy up to `frames` interleaved frames from `src`.
    /// Returns dropped frame count (non-zero only on overflow).
    @discardableResult
    func write(_ src: UnsafePointer<Float>, frames: Int) -> Int {
        let (r, w) = indices()
        let free = capacityFrames - (w - r)
        let toWrite = min(frames, free)
        if toWrite > 0 {
            let start = w % capacityFrames
            let firstChunk = min(toWrite, capacityFrames - start)
            memcpy(storage + start * channels, src, firstChunk * channels * MemoryLayout<Float>.size)
            if toWrite > firstChunk {
                memcpy(storage, src + firstChunk * channels, (toWrite - firstChunk) * channels * MemoryLayout<Float>.size)
            }
            os_unfair_lock_lock(lock)
            writeFrame = w + toWrite
            os_unfair_lock_unlock(lock)
        }
        return frames - toWrite
    }

    /// Consumer: discard the oldest `frames` (drift compensation — keeps latency
    /// bounded when the producer's clock outruns the consumer's). Consumer-side
    /// only, so it's safe to advance the read index here.
    func dropOldest(_ frames: Int) {
        let (r, w) = indices()
        let drop = min(frames, w - r)
        if drop > 0 {
            os_unfair_lock_lock(lock)
            readFrame = r + drop
            os_unfair_lock_unlock(lock)
        }
    }

    /// Consumer: copy up to `frames` interleaved frames into `dst`.
    /// Any shortfall is left untouched (caller must have zeroed `dst`).
    /// Returns the underflow frame count (frames we couldn't supply).
    @discardableResult
    func read(_ dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let (r, w) = indices()
        let avail = w - r
        let toRead = min(frames, avail)
        if toRead > 0 {
            let start = r % capacityFrames
            let firstChunk = min(toRead, capacityFrames - start)
            memcpy(dst, storage + start * channels, firstChunk * channels * MemoryLayout<Float>.size)
            if toRead > firstChunk {
                memcpy(dst + firstChunk * channels, storage, (toRead - firstChunk) * channels * MemoryLayout<Float>.size)
            }
            os_unfair_lock_lock(lock)
            readFrame = r + toRead
            os_unfair_lock_unlock(lock)
        }
        return frames - toRead
    }
}
