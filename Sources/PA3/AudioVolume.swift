import AudioToolbox
import CoreAudio
import Foundation

/// Reads and sets the system's default output volume via CoreAudio (no AppleScript).
enum OutputVolume {
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Current master output volume in 0.0...1.0, or nil if the device doesn't expose it.
    static func current() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Float(volume)
    }

    /// Sets the master output volume (clamped to 0.0...1.0). Returns false if unsupported.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var volume = Float32(max(0, min(1, value)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume)
        return status == noErr
    }
}
