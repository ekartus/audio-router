import XCTest
@testable import MixerCore

final class RingBufferTests: XCTestCase {
    func testWraparoundPreservesInterleavedFrames() {
        let ring = AudioRingBuffer(capacityFrames: 4, channels: 2)
        let first = [Float](arrayLiteral: 1, 10, 2, 20, 3, 30)
        let second = [Float](arrayLiteral: 4, 40, 5, 50, 6, 60)
        var output = [Float](repeating: 0, count: 6)

        first.withUnsafeBufferPointer { source in
            XCTAssertEqual(ring.write(source.baseAddress!, frames: 3), 0)
        }
        output.withUnsafeMutableBufferPointer { destination in
            XCTAssertEqual(ring.read(destination.baseAddress!, frames: 2), 0)
        }
        XCTAssertEqual(output, [1, 10, 2, 20, 0, 0])

        second.withUnsafeBufferPointer { source in
            XCTAssertEqual(ring.write(source.baseAddress!, frames: 4), 1)
        }
        output = [Float](repeating: 0, count: 6)
        output.withUnsafeMutableBufferPointer { destination in
            XCTAssertEqual(ring.read(destination.baseAddress!, frames: 3), 0)
        }
        XCTAssertEqual(output, [3, 30, 4, 40, 5, 50])
    }

    func testDiscardNeverAdvancesPastAvailableFrames() {
        let ring = AudioRingBuffer(capacityFrames: 4, channels: 1)
        let input = [Float](arrayLiteral: 1, 2, 3)
        input.withUnsafeBufferPointer { source in
            XCTAssertEqual(ring.write(source.baseAddress!, frames: 3), 0)
        }

        ring.discard(frames: 2)
        var output = [Float](repeating: 0, count: 2)
        output.withUnsafeMutableBufferPointer { destination in
            XCTAssertEqual(ring.read(destination.baseAddress!, frames: 2), 1)
        }
        XCTAssertEqual(output[0], 3)
    }
}
