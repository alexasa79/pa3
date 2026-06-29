import AudioToolbox
import CoreAudio
import Foundation

/// Reads and sets the system's default output volume via CoreAudio (no AppleScript).
enum OutputVolume {
    static func defaultOutputDevice() -> AudioDeviceID? {
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

    /// Current default input device, for diagnostics (the Bluetooth profile switch that
    /// moves output routing only happens when the headset is also the input device).
    static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Human-readable name of a device, for logging.
    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
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
        return current(device: device)
    }

    /// Current master output volume of a specific device, or nil if it doesn't expose one.
    static func current(device: AudioDeviceID) -> Float? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Float(volume)
    }

    /// Sets the master output volume of the default device (clamped to 0.0...1.0). Returns false if unsupported.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        return set(value, device: device)
    }

    /// Sets the master output volume of a specific device (clamped to 0.0...1.0). Returns false if unsupported.
    @discardableResult
    static func set(_ value: Float, device: AudioDeviceID) -> Bool {
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

/// Ducks the system output volume while dictating and restores it afterward.
///
/// Bluetooth headsets keep *separate* volume memory for their music profile and their
/// low-quality headset (microphone) profile. Opening the mic switches the device to the
/// headset profile mid-session, which resets the live volume; switching back to the music
/// profile ~1-2s after the mic closes resurfaces whatever value that profile last held —
/// including the ducked value we wrote into it. So a one-shot duck/restore leaves the music
/// profile poisoned and the volume stuck low after dictation ends.
///
/// To cope we keep a listener on the device's volume that re-asserts a moving `target`
/// (the duck level while dictating, the original volume while winding down). After stop we
/// also watch the device's nominal sample rate: the headset profile runs at a low rate, so
/// the jump back up signals the music-profile switch-back, at which point we re-apply the
/// original volume and tear everything down.
///
/// All access happens on the main actor: callers invoke `start`/`stop` from there, and the
/// CoreAudio listeners and timers are delivered on the main queue too, so the bookkeeping
/// needs no lock (the callbacks `assumeIsolated` since they already run on the main queue).
@MainActor
final class OutputDucker {
    private let level: Float
    /// Nominal sample rates below this mean the Bluetooth headset (mic) profile is active;
    /// music profiles run at 44.1/48 kHz, the headset profile at 8/16/24 kHz.
    private let musicSampleRateThreshold: Float64 = 32000
    /// Hard cap on how long we keep correcting after stop, in case the switch-back never
    /// arrives (e.g. wired output, or the headphones get disconnected).
    private let maxWindDownSeconds: TimeInterval = 8

    private enum Phase { case idle, ducking, windingDown }
    private var phase: Phase = .idle

    private var device: AudioDeviceID?
    private var originalVolume: Float?
    /// Volume the listener keeps re-asserting against profile-switch resets.
    private var targetVolume: Float?

    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var teardownItem: DispatchWorkItem?

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(level: Float) {
        self.level = level
    }

    var isActive: Bool { phase != .idle }

    func start() {
        switch phase {
        case .ducking:
            return
        case .windingDown:
            // A new session began before the previous wind-down finished (e.g. toggling the
            // hotkey off and back on). The device, original volume and listeners are still
            // live, so re-arm in place rather than bailing out and leaving the target stuck
            // at the un-ducked volume.
            guard let dev = device else { return }
            teardownItem?.cancel()
            teardownItem = nil
            targetVolume = level
            phase = .ducking
            Logger.info("OutputDucker.restart device=\(dev) duck=\(level)")
            reapplyTarget(on: dev)
        case .idle:
            guard let dev = OutputVolume.defaultOutputDevice(),
                  let original = OutputVolume.current(device: dev) else { return }
            device = dev
            originalVolume = original
            targetVolume = level
            phase = .ducking
            Logger.info("OutputDucker.start device=\(dev) (\(OutputVolume.name(of: dev))) original=\(original) duck=\(level)")
            installVolumeListener(on: dev)
            installSampleRateListener(on: dev)
            reapplyTarget(on: dev)
        }
    }

    func stop() {
        guard phase == .ducking, let dev = device else { return }
        let original = originalVolume ?? level
        targetVolume = original
        phase = .windingDown
        let rate = sampleRate(of: dev)
        Logger.info("OutputDucker.stop device=\(dev) restore=\(original) sampleRate=\(rate.map { String($0) } ?? "nil")")
        reapplyTarget(on: dev)
        // If the headset (mic) profile is active, the switch back to the music profile lands
        // ~1-2s later and resurfaces the poisoned ducked value; the sample-rate listener
        // catches that and re-applies the original. Otherwise nothing more will happen, so
        // tear down now.
        if let rate, rate < musicSampleRateThreshold {
            scheduleTeardown(after: maxWindDownSeconds)
        } else {
            teardown()
        }
    }

    // MARK: - Listeners

    private func installVolumeListener(on dev: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.enforceTarget(reason: "volume") }
        }
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(dev, &volumeAddress, DispatchQueue.main, block)
    }

    private func installSampleRateListener(on dev: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sampleRateChanged() }
        }
        sampleRateListener = block
        AudioObjectAddPropertyListenerBlock(dev, &sampleRateAddress, DispatchQueue.main, block)
    }

    /// Re-assert the current target if the live volume has drifted away from it (e.g. a
    /// Bluetooth profile switch resetting the volume). Safe to call spuriously.
    private func enforceTarget(reason: String) {
        guard let dev = device, let target = targetVolume,
              let current = OutputVolume.current(device: dev) else { return }
        if abs(current - target) > 0.005 {
            OutputVolume.set(target, device: dev)
            Logger.info("OutputDucker.reassert reason=\(reason) device=\(dev) was=\(current) -> \(target) phase=\(phase)")
        }
    }

    /// A Bluetooth profile switch shows up as a sample-rate change: the headset (mic) profile
    /// runs at a low rate, the music profile high. Either way the live volume is reset, so we
    /// push the current target back onto the now-active profile.
    private func sampleRateChanged() {
        guard let dev = device else { return }
        let rate = sampleRate(of: dev) ?? 0
        Logger.info("OutputDucker.sampleRate device=\(dev) -> \(rate) phase=\(phase)")
        reapplyTarget(on: dev)
        if phase == .windingDown && rate >= musicSampleRateThreshold {
            // Music profile restored; let any trailing reset settle, then stop correcting.
            scheduleTeardown(after: 1)
        }
    }

    /// Write the target now and again over the next second. The profile switch's volume reset
    /// can land slightly after its sample-rate notification, so a single write may be undone;
    /// the follow-ups win the race without busy-polling.
    private func reapplyTarget(on dev: AudioDeviceID) {
        enforceTarget(reason: "immediate")
        for delay in [0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.device == dev else { return }
                    self.enforceTarget(reason: "delayed+\(delay)")
                }
            }
        }
    }

    // MARK: - Teardown

    private func scheduleTeardown(after seconds: TimeInterval) {
        teardownItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.teardown() }
        }
        teardownItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func teardown() {
        if let dev = device {
            if let block = volumeListener {
                AudioObjectRemovePropertyListenerBlock(dev, &volumeAddress, DispatchQueue.main, block)
            }
            if let block = sampleRateListener {
                AudioObjectRemovePropertyListenerBlock(dev, &sampleRateAddress, DispatchQueue.main, block)
            }
            Logger.info("OutputDucker.teardown device=\(dev) final=\(OutputVolume.current(device: dev).map { String($0) } ?? "nil")")
        }
        volumeListener = nil
        sampleRateListener = nil
        teardownItem?.cancel()
        teardownItem = nil
        device = nil
        originalVolume = nil
        targetVolume = nil
        phase = .idle
    }

    private func sampleRate(of device: AudioDeviceID) -> Float64? {
        var address = sampleRateAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }
}
