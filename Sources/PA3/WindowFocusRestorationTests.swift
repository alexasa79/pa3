import Foundation

func runWindowFocusRestorationTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("window focus: " + name) }
    }
    let focused = WindowFocusRestoration.Snapshot(key: true, appActive: true)
    let inactive = WindowFocusRestoration.Snapshot()
    let away = WindowFocusRestoration.Snapshot(onActiveSpace: false)
    let missionControl = WindowFocusRestoration.Snapshot(missionControl: true)

    var state = WindowFocusRestoration()
    check(!state.update(focused, now: 0), "gaining focus only arms restoration")
    check(!state.update(away, now: 1), "leaving does not activate PA3 on another desktop")
    check(!state.update(away, now: 100), "another desktop can remain active indefinitely")
    check(!state.update(inactive, now: 101), "waits for the return animation")
    check(state.update(inactive, now: 101.3), "returning to the desktop restores focus")
    check(!state.update(inactive, now: 102), "restores at most once")

    state.reset()
    _ = state.update(focused, now: 0)
    _ = state.update(inactive, now: 1)
    _ = state.update(inactive, now: 1.8)
    _ = state.update(away, now: 2.2)
    _ = state.update(inactive, now: 3)
    check(state.update(inactive, now: 3.3), "handles deactivation arriving before the Space notification")

    state.reset()
    _ = state.update(focused, now: 0)
    check(!state.update(inactive, now: 1), "ordinary app switch does not restore focus")
    check(!state.update(inactive, now: 2.6) && !state.ownsFocus, "intentional app switch relinquishes focus")
    _ = state.update(away, now: 2.7)
    _ = state.update(inactive, now: 3)
    check(!state.update(inactive, now: 4), "later desktop switches do not revive stale ownership")

    state.reset()
    _ = state.update(focused, now: 0)
    _ = state.update(.init(appActive: true), now: 1)
    _ = state.update(.init(appActive: true), now: 10)
    _ = state.update(away, now: 11)
    _ = state.update(inactive, now: 12)
    check(state.update(inactive, now: 12.3), "an interactive swipe can suspend the key window before deactivation")

    state.reset()
    _ = state.update(focused, now: 0)
    _ = state.update(inactive, now: 1)
    check(!state.update(missionControl, now: 1.2), "Mission Control does not trigger early activation")
    check(!state.update(missionControl, now: 120), "Mission Control may stay open without a timeout")
    _ = state.update(inactive, now: 121)
    check(state.update(inactive, now: 121.3), "exiting Mission Control on the same desktop restores focus")

    state.reset()
    _ = state.update(focused, now: 0)
    _ = state.update(missionControl, now: 1)
    _ = state.update(away, now: 2)
    check(!state.update(away, now: 3), "exiting Mission Control on another desktop waits")
    _ = state.update(inactive, now: 4)
    _ = state.update(away, now: 4.1)
    _ = state.update(inactive, now: 5)
    check(!state.update(inactive, now: 5.1), "rapid desktop changes restart the settle delay")
    check(state.update(inactive, now: 5.3), "rapid desktop changes eventually restore on the correct desktop")

    for (name, cancelled) in [
        ("disabled pin", WindowFocusRestoration.Snapshot(enabled: false)),
        ("hidden or minimized window", WindowFocusRestoration.Snapshot(visible: false)),
        ("another PA3 window", WindowFocusRestoration.Snapshot(otherPA3WindowIsKey: true))
    ] {
        state.reset()
        _ = state.update(focused, now: 0)
        _ = state.update(away, now: 1)
        _ = state.update(cancelled, now: 2)
        _ = state.update(inactive, now: 3)
        check(!state.update(inactive, now: 4) && !state.ownsFocus, "\(name) cancels pending restoration")
    }

    state.reset()
    _ = state.update(focused, now: 0)
    _ = state.update(away, now: 1)
    state.reset()
    _ = state.update(inactive, now: 2)
    check(!state.update(inactive, now: 3), "explicit dismissal cancels pending restoration")

    state.reset()
    _ = state.update(focused, now: 0)
    _ = state.update(away, now: 1)
    check(!state.update(focused, now: 2), "native focus restoration needs no extra activation")
    check(!state.update(focused, now: 3) && state.ownsFocus, "native focus restoration rearms the next transition")

    state.reset()
    _ = state.update(missionControl, now: 0)
    _ = state.update(inactive, now: 1)
    check(!state.update(inactive, now: 2), "an initially unfocused PA3 never steals focus")
    return failures
}
