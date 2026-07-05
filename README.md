
build:

mkdir -p ChromeFullscreen.app/Contents/MacOS
swiftc -O chrome_fullscreen_windows.swift -o ChromeFullscreen.app/Contents/MacOS/ChromeFullscreen

sign it:
codesign --force --options runtime --sign - ChromeFullscreen.app

run it:

ChromeFullscreen.app/Contents/MacOS/ChromeFullscreen [<args>]

or

open ChromeFullscreen.app

or

using Spotlight.

Script args:

- no args — print fullscreen Chrome window IDs (titles on stderr)
- --restore <window-id> — un-fullscreen one window (no-op with exit 0 if it isn't fullscreen)
- --restore-all — un-fullscreen every fullscreen Chrome window

Note that you need to grant accessibilty, and depending on how you launch it, it's either the terminal app or the app itself that you need to grant accessibility rights to.
