# Contributing

## Build and test

```sh
flutter pub get && flutter analyze && flutter test
(cd example/android && ./gradlew :kirora_flutter:testDebugUnitTest)   # Android bridge
(cd example && flutter build apk --debug)
(cd example && flutter build ios --simulator)
```

To build against unreleased native code: on Android, set `KIRORA_ANDROID_LOCAL=1` after running
`./gradlew publishToMavenLocal` in `kirora-android`. On iOS, set `KIRORA_IOS_PATH` to a
`kirora-ios` checkout for Swift Package Manager (the folder must have that name; `flutter clean`
if Xcode keeps the old package), or run `tool/sync_kirora_ios.sh /path/to/kirora-ios` for
CocoaPods. A new kirora-ios release: `tool/sync_kirora_ios.sh <tag>` and the same exact version in
`ios/kirora_flutter/Package.swift`.

The Android example builds without Firebase; live push needs your own Firebase project and
a device. CI builds both platforms against the released native SDKs on every change. Real-device
push and several engines in one app are not covered by automated tests.

## Release

1. Set the new version in `pubspec.yaml` and `lib/src/version.dart` (a test checks they agree),
   and add it to `CHANGELOG.md`. For a new kirora-ios, run `tool/sync_kirora_ios.sh <tag>` and
   set the same exact version in `ios/kirora_flutter/Package.swift`; for a new Android SDK, the
   default in `android/build.gradle.kts`. Update the native versions the README names.
2. Merge to `main` with CI green.
3. Tag the commit `vX.Y.Z` and push the tag. The "Publish to pub.dev" workflow tests the package
   and publishes it; pub.dev accepts only tags matching `v{{version}}` from this repository.
