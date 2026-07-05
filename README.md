A hacky fix to how Screen Time will change some/all Chrome windows to be in Fullscreen mode when the screen time timers trigger. This will un-fullscreen all Chrome windows.

build:

mkdir -p ChromeFullscreen.app/Contents/MacOS
swiftc -O chrome_fullscreen_windows.swift -o ChromeFullscreen.app/Contents/MacOS/ChromeFullscreen

sign it:
codesign --force --options runtime --sign - ChromeFullscreen.app

run it:

ChromeFullscreen.app/Contents/MacOS/ChromeFullscreen [<args>]

Ideally run the app directly, and ensure that it appears in the Settings > Privacy & Security > Accessibility list and is allowed to control the computer. (this doesn't have an UX, so it will silently do its thing, to debug run the CLI version)

Script args:

- no args — print fullscreen Chrome window IDs (titles on stderr)
- --restore <window-id> — un-fullscreen one window (no-op with exit 0 if it isn't fullscreen)
- --restore-all — un-fullscreen every fullscreen Chrome window

Note that you need to grant accessibilty, and depending on how you launch it, it's either the terminal app or the app itself that you need to grant accessibility rights to.
