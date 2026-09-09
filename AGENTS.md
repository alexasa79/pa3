# PA3 workflow

After changes to the app, run the appropriate tests, rebuild with `make app`, and restart PA3 so the user can use the updated build immediately. This is the user's standing preference; do not require a separate rebuild or restart request unless the user explicitly asks to defer it.

Quit the running app cleanly using its bundle identifier `com.local.pa3`, wait for it to exit, then launch this checkout's `PA3.app`. Verify that the new process is running from that bundle and that startup completed successfully.
