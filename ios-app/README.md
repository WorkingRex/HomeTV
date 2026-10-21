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
increases repeat speed, and releasing stops immediately. Tilt and joystick modes
each retain an OK button. Leaving the app or losing the connection resets the
mode to direction buttons and stops continuous input.

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