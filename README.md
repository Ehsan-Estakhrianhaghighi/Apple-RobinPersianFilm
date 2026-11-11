# RobinPersianFilm — Apple TV + iPhone

An independent native SwiftUI implementation. It contains separate iOS and tvOS targets sharing catalog and stream resolver code. It does not run the Android APK.

## Install from your MacBook

1. Install Xcode, open it and accept its components.
2. Install XcodeGen: `brew install xcodegen`.
3. Clone `Apple-RobinPersianFilm`, open Terminal at the repository root and run:

   ```sh
   xcodegen generate
   open RobinPersianFilmApple.xcodeproj
   ```

   Or run `bash setup-mac.sh`.

4. Select scheme **RobinPersianFilmTV** for Apple TV or **RobinPersianFilmIOS** for iPhone. Set your Apple team under Signing & Capabilities.
5. Pair Apple TV with Xcode using Window > Devices and Simulators, then choose it as the run destination and Run.
6. For iPhone, pair the phone with Xcode, enable Developer Mode when prompted, then Run.

Apple TV uses a separate tvOS app rather than an iPhone IPA. A Mac with Xcode is required for physical-device signing.

## Functionality

- Home, Movies, Series, Favorites, History; search, Newest and A–Z.
- FarsiPlex and FarsiLand catalogs, preferring FarsiPlex for matching titles.
- FarsiLand episode and movie POST-form resolver using per-title published inputs and cookies.
- FarsiPlex published MP4 extraction and verified filename resolution substitutions.
- AVPlayer, verified quality choices, fullscreen, Apple TV remote playback controls, favorites/history.

## Limitations

Provider HTML, POST forms, cookies and signed streams may change. The tvOS app cannot support browser-only access flows and does not bypass required access gates. Signed media URLs are resolved at playback time, never committed into source control.

GitHub Actions checks unsigned iOS and tvOS Simulator builds; those are not installable device builds. Use Xcode on your Mac to sign and install. Only access streams you are authorized to view.
