import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Low-level property helpers

enum CA {
    /// Read a variable-length array property (e.g. device list, process list).
    static func objectIDs(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr, dataSize > 0
        else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, $0.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    /// Read a CFString property as a Swift String.
    static func string(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfStr: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr, let s = cfStr else { return nil }
        return s as String
    }

    /// Read a fixed-size scalar property.
    static func scalar<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          default def: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = def
        var dataSize = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    /// Read an AudioStreamBasicDescription property (device or tap format).
    static func format(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &asbd)
        return status == noErr ? asbd : nil
    }

    /// Nominal sample rate of a device.
    static func sampleRate(_ objectID: AudioObjectID) -> Double? {
        scalar(objectID, kAudioDevicePropertyNominalSampleRate, default: Double(0))
    }

    /// Number of channels a device exposes in the given scope (output/input).
    static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Model types

public struct AudioDeviceInfo: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let outputChannels: Int
    public var isOutput: Bool { outputChannels > 0 }
}

public struct AudioProcessInfo {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
}

// MARK: - Enumeration

public func listOutputDevices() -> [AudioDeviceInfo] {
    let ids = CA.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return ids.compactMap { id in
        let uid = CA.string(id, kAudioDevicePropertyDeviceUID) ?? "?"
        let name = CA.string(id, kAudioObjectPropertyName) ?? "Unknown"
        let out = CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        return AudioDeviceInfo(id: id, uid: uid, name: name, outputChannels: out)
    }.filter { $0.isOutput }
}

public func listAudioProcesses() -> [AudioProcessInfo] {
    let ids = CA.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    return ids.map { id in
        let pid: pid_t = CA.scalar(id, kAudioProcessPropertyPID, default: pid_t(-1)) ?? -1
        let bundle = CA.string(id, kAudioProcessPropertyBundleID)
        return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle)
    }
}

/// Resolve the audio process object for a bundle id (exact, case-insensitive).
public func audioProcess(forBundleID bundleID: String) -> AudioProcessInfo? {
    listAudioProcesses().first { ($0.bundleID ?? "").caseInsensitiveCompare(bundleID) == .orderedSame }
}

/// Resolve an output device by its stable UID.
public func outputDevice(forUID uid: String) -> AudioDeviceInfo? {
    listOutputDevices().first { $0.uid == uid }
}

/// The current system default output device — where all un-routed audio goes.
public func defaultOutputDevice() -> AudioDeviceInfo? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var devID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devID) == noErr,
          devID != 0 else { return nil }
    let uid = CA.string(devID, kAudioDevicePropertyDeviceUID) ?? "?"
    let name = CA.string(devID, kAudioObjectPropertyName) ?? "Unknown"
    let out = CA.channelCount(devID, scope: kAudioObjectPropertyScopeOutput)
    return AudioDeviceInfo(id: devID, uid: uid, name: name, outputChannels: out)
}
