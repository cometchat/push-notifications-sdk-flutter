# Running the Swift tests

The package's sources import `Flutter`, which no plain `swift test` can
resolve, so the tests build against the engine's simulator
`Flutter.xcframework`. From `ios/cometchat_voip`, with `FLUTTER_ROOT` set to
the Flutter SDK (the one `flutter --version` reports):

```sh
SIM="$FLUTTER_ROOT/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
xcodebuild test \
  -scheme cometchat_voip \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/cometchat_voip_tests \
  FRAMEWORK_SEARCH_PATHS="$SIM" \
  OTHER_LDFLAGS="-F $SIM -framework Flutter" \
  LD_RUNPATH_SEARCH_PATHS="@loader_path/Frameworks @executable_path/Frameworks $SIM"
```

Flutter's plugin integration builds the library product only; the test
target never reaches an app.
