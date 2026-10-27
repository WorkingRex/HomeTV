# HomeTV iOS app

This folder contains the native SwiftUI app. The app will connect directly to Android TV over the local network using Android TV Remote Protocol v2.

## Generate the Xcode project

```bash
xcodegen generate
```

## Build and test in the iPhone 17 Simulator

```bash
xcodebuild \
  -project HomeTV.xcodeproj \
  -scheme HomeTV \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The app supports Android TV discovery, pairing, and remote commands. The power
button next to Back and Home sends the Android TV POWER toggle command while
connected. Waking the TV from standby depends on the TV keeping its network and
remote service available; the app cannot wake a fully powered-off TV.

## Direction control modes

Use the fixed bottom selector to switch between direction buttons, Tilt, and
joystick controls. The active direction control panel sits directly above the
selector in the same fixed bottom area, separate from the scrolling remote buttons.
Tilt automatically calibrates on entry and stops when leaving
the mode or the app. It requires a physical device with motion sensors.
Drag the joystick to send four-direction key presses; moving farther from center
increases repeat speed, and releasing stops immediately. Tilt retains an OK
button; joystick mode uses its central OK knob without a separate button or
inline instructions. Leaving the app or losing the connection resets the
mode to direction buttons and stops continuous input.
Tapping the joystick's central OK knob also confirms. A drag (even if it returns
to center) or a press longer than half a second does not confirm on release.

## App-aware playback controls

Fixed controls (Back, Home, Power, and volume) are placed above app-specific
playback controls. Play/pause, rewind, and fast-forward appear automatically
only when the TV reports YouTube or Netflix. They are hidden for other or unknown
apps. Direction controls remain in the fixed bottom panel. App and tilt
diagnostic hints stay hidden in an info popover next to the mode selector. The displayed app is the most
recent package reported through the remote protocol's IME messages, not a
guaranteed live foreground-app query; reports may be delayed or unavailable.
App information is cleared when the remote connection leaves the connected state.
The client negotiates IME support and replies to the TV's activation request
before waiting for the remote-start event. If the TV does not advertise IME
support, the UI explains that app reporting is unavailable. Xcode's console
includes `RemoteSession` diagnostics for negotiated features, activation,
session start, and reported app packages (without text-field contents).

To pair the selected TV again, tap its status row, choose **重新配對**,
confirm, then enter the code shown on the TV. The app reuses its saved identity
and keeps it unless a pairing completes with the TV.
The main screen keeps a fixed-height status row with the TV name and a green
dot when connected. Tap it to open connection settings in a sheet without
expanding or resizing the remote layout. Discovery and pairing share this sheet;
closing settings alone does not disconnect an established session.

Remote connections have a 10-second deadline covering TLS and the protocol
handshake. Reconnecting with an existing identity retries up to three attempts;
failure preserves the identity and reports an error instead of automatically
starting pairing. A closed socket is reported rather than left in "Connecting".
If the TV closes the remote socket while switching apps, an established session
also retries the existing paired connection up to two times before reporting an
error; it does not request a new pairing code.
When testing multiple phones, close HomeTV on the other phone to check whether
the TV's remote service permits concurrent sessions. Pairing storage and
simultaneous connection support are separate capabilities.
New client certificates and pairing client names are unique per installation.
Explicit re-pairing upgrades legacy certificates named only `HomeTV Remote`,
keeping the existing private key. This changes the certificate used with all
previously paired TVs, which may each require re-pairing. Existing uniquely named
certificates are reused, not regenerated on every launch or re-pair.

App shortcuts are stored locally on each phone. With the TV connected and an app
reported, tap **+** to add it. Duplicate apps are ignored. Tap a shortcut to
launch it. Long-press any control button to enter edit mode; only then can
shortcuts and fixed controls be dragged to rearrange, and shortcut X buttons
appear for deletion. Tap **完成** to leave edit mode. The direction control
panel remains fixed.
Reordering updates live as a dragged tile enters each target, then persists on
drop. The dragged tile dims and neighboring controls animate into the new
positions.
The TV protocol reports package names, not original app artwork, so YouTube and
Netflix use built-in recognizable glyphs and other apps use a generic app icon.
Launching uses app-specific links for YouTube and Netflix and an
`android-app://` URI for other reported Android packages. Existing single-app
shortcut settings are migrated into the new shortcut list on first launch.