import Foundation

@MainActor
private final class TestOutputMuter: AudioOutputMuting {
    var isActive = false
    var starts = 0
    var stops = 0

    func start() { isActive = true; starts += 1 }
    func stop() { isActive = false; stops += 1 }
}

@MainActor
func runAutoMuteTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append("auto mute: " + message) }
    }
    let suite = "com.local.pa3.tests.auto-mute.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let muter = TestOutputMuter()
    let controller = DictationController(transcriber: TranscriberService(), preferences: preferences, outputMuter: muter)
    check(controller.autoMuteAudio && muter.starts == 0, "defaults to enabled without muting while paused")
    controller.autoMuteAudio = false
    let restored = DictationController(transcriber: TranscriberService(),
                                      preferences: UserDefaults(suiteName: suite)!, outputMuter: TestOutputMuter())
    check(!restored.autoMuteAudio, "disabled preference is restored in a new controller")
    check(muter.starts == 0 && muter.stops == 0, "changing preference while paused leaves output untouched")

    controller.dictating = true // Simulate capture without opening the microphone or changing system audio.
    controller.autoMuteAudio = true
    check(muter.isActive && muter.starts == 1, "enabling during dictation starts muting immediately")
    controller.autoMuteAudio = false
    check(!muter.isActive && muter.stops == 1 && controller.dictating,
          "disabling during dictation restores output without stopping dictation")
    controller.autoMuteAudio = true
    check(muter.isActive && muter.starts == 2, "re-enabling during dictation starts muting again")
    controller.stopDictation()
    check(!muter.isActive && muter.stops == 2, "pausing always restores output")
    let deadline = Date().addingTimeInterval(2)
    while !controller.canStartDictation && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(controller.canStartDictation, "pause completes")
    controller.autoMuteAudio = false
    controller.beginNewSession()
    check(!controller.autoMuteAudio && muter.starts == 2 && muter.stops == 2,
          "new session preserves the disabled preference without touching output")
    controller.autoMuteAudio = true
    let restoredEnabled = DictationController(transcriber: TranscriberService(),
                                             preferences: UserDefaults(suiteName: suite)!, outputMuter: TestOutputMuter())
    check(restoredEnabled.autoMuteAudio, "enabled preference is restored in a new controller")
    return failures
}
