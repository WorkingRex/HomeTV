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

The current screen is a UI scaffold. Android TV discovery, pairing, TLS, Keychain storage, and command transport are the next implementation layer.