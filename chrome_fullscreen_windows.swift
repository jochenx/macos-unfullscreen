// chrome_fullscreen_windows.swift
//
// Lists Chrome windows that are in native macOS fullscreen, ACROSS ALL SPACES,
// and can revert them to regular windows.
//
// Usage:
//   chrome_fullscreen_windows                 un-fullscreen every fullscreen window
//   chrome_fullscreen_windows --restore-all   same, explicitly
//   chrome_fullscreen_windows --restore <id>  un-fullscreen one window
//   chrome_fullscreen_windows --list          just list fullscreen window IDs
//
// Exits 1 immediately if Accessibility permission is missing.
//
// Why the naive version fails: kAXWindowsAttribute only returns windows on the
// *current* Space, and a fullscreen window always lives on its own Space — so
// the one window you're looking for is precisely the one AX won't list.
//
// Fix: enumerate Chrome's windows via CGWindowList (sees all Spaces), then for
// windows the AX list can't reach, build AXUIElements directly from remote
// tokens (_AXUIElementCreateWithRemoteToken + _AXUIElementGetWindow — the same
// private-but-stable trick yabai/alt-tab-macos use) and query AXFullScreen.
//
// Build: swiftc -O chrome_fullscreen_windows.swift -o chrome_fullscreen_windows
// Requires Accessibility permission for the parent process (e.g. your terminal).

import Cocoa
import ApplicationServices

// MARK: private AX bridges

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// AX element from a per-process element ID (a small counter, not the CGWindowID).
func remoteAXElement(pid: pid_t, elementID: UInt64) -> AXUIElement? {
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    // bytes 4..8 stay zero
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) }) // 'coco'
    token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
    return _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue()
}

// MARK: helpers

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
    return ref as? T
}

func windowID(of element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
    return wid
}

// MARK: window discovery

/// All Chrome AX windows keyed by CGWindowID, across all Spaces.
func chromeWindows(pid: pid_t) -> [CGWindowID: AXUIElement] {
    // 1. All Chrome window IDs across all Spaces, from the CG side (layer 0 = real windows).
    var cgWindowIDs = Set<CGWindowID>()
    if let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
        for w in info {
            guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            cgWindowIDs.insert(num)
        }
    }

    var axWindowsByID = [CGWindowID: AXUIElement]()

    // 2. Fast path: AX windows list (current Space + minimized only).
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
       let windowsArray = windowsRef as? NSArray {
        // `as? [AXUIElement]` can fail to bridge; go through NSArray element by element
        for case let window as AXUIElement in windowsArray {
            if let wid = windowID(of: window) { axWindowsByID[wid] = window }
        }
    }

    // 3. Windows AX couldn't see (other Spaces): reach them via remote tokens.
    //    Element IDs count up per process; stop as soon as every CG window is matched.
    var missing = cgWindowIDs.subtracting(axWindowsByID.keys)
    if !missing.isEmpty {
        for elementID: UInt64 in 0..<200_000 {
            guard let el = remoteAXElement(pid: pid, elementID: elementID),
                  let wid = windowID(of: el), missing.contains(wid),
                  (attribute(el, kAXRoleAttribute as String) as String?) == kAXWindowRole as String
            else { continue }
            axWindowsByID[wid] = el
            missing.remove(wid)
            if missing.isEmpty { break }
        }
    }

    return axWindowsByID
}

func isFullscreen(_ window: AXUIElement) -> Bool {
    (attribute(window, "AXFullScreen") as Bool?) == true
}

/// Revert a fullscreen window to a regular window (returns it to the normal Space).
func exitFullscreen(_ window: AXUIElement, wid: CGWindowID) -> Bool {
    let err = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
    guard err == .success else {
        fputs("window \(wid): AXUIElementSetAttributeValue failed (AXError \(err.rawValue))\n", stderr)
        return false
    }
    // The transition is animated; poll until the attribute flips (or time out).
    for _ in 0..<40 {  // up to ~2s
        if !isFullscreen(window) { return true }
        usleep(50_000)
    }
    fputs("window \(wid): set succeeded but window still reports fullscreen\n", stderr)
    return false
}

// MARK: main

guard AXIsProcessTrusted() else {
    fputs("No Accessibility permission (System Settings → Privacy & Security → Accessibility) — exiting.\n", stderr)
    exit(1)
}

guard let chrome = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.google.Chrome" }) else {
    print("Chrome is not running"); exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let windows = chromeWindows(pid: chrome.processIdentifier)

switch args.first {
case "--restore":
    guard args.count == 2, let rawID = UInt32(args[1]) else {
        fputs("usage: chrome_fullscreen_windows --restore <window-id>\n", stderr); exit(2)
    }
    let wid = CGWindowID(rawID)
    guard let window = windows[wid] else {
        fputs("window \(wid): not found among Chrome's windows\n", stderr); exit(1)
    }
    guard isFullscreen(window) else {
        fputs("window \(wid): not fullscreen, nothing to do\n", stderr); exit(0)
    }
    exit(exitFullscreen(window, wid: wid) ? 0 : 1)

case nil, "--restore-all":
    var failures = 0
    for (wid, window) in windows.sorted(by: { $0.key < $1.key }) where isFullscreen(window) {
        let title: String = attribute(window, kAXTitleAttribute as String) ?? "<untitled>"
        fputs("restoring window \(wid) \"\(title)\"\n", stderr)
        if !exitFullscreen(window, wid: wid) { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)

case "--list":
    var fullscreenIDs: [CGWindowID] = []
    for (wid, window) in windows.sorted(by: { $0.key < $1.key }) where isFullscreen(window) {
        fullscreenIDs.append(wid)
        let title: String = attribute(window, kAXTitleAttribute as String) ?? "<untitled>"
        fputs("fullscreen: window \(wid) \"\(title)\"\n", stderr)
    }
    print(fullscreenIDs)

default:
    fputs("usage: chrome_fullscreen_windows [--list | --restore <window-id> | --restore-all]\n", stderr)
    exit(2)
}
