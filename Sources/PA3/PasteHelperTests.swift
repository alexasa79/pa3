import ApplicationServices
import Carbon
import IOKit.hidsystem

func runPasteHelperTests() -> [String] {
    guard let events = PasteHelper.makePasteEvents(), events.count == 4 else {
        return ["paste must produce a complete four-event chord"]
    }
    var failures: [String] = []
    var commandHeld = false
    var vHeld = false
    var presses = 0
    for event in events {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let leftCommand = event.flags.rawValue & UInt64(NX_DEVICELCMDKEYMASK) != 0
        if event.flags.contains(.maskCommand) != leftCommand {
            failures.append("general and left Command flags disagree")
        }
        if event.flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0 {
            failures.append("paste spuriously holds right Command")
        }
        if event.type == .flagsChanged && key == kVK_Command {
            commandHeld = event.flags.contains(.maskCommand)
            if !commandHeld && vHeld { failures.append("Command released before V") }
        } else if key == kVK_ANSI_V {
            if !commandHeld || !event.flags.contains(.maskCommand) {
                failures.append("remote receiver would see V without Command")
            }
            if event.type == .keyDown { vHeld = true; presses += 1 }
            else if event.type == .keyUp { vHeld = false }
            else { failures.append("unexpected V event type") }
        } else {
            failures.append("unexpected key in paste chord")
        }
    }
    if commandHeld || vHeld { failures.append("paste leaves a synthetic key held") }
    if presses != 1 { failures.append("paste must press V exactly once") }
    return failures
}
