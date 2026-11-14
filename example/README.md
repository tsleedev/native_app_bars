# Native Chrome example

Run `flutter run` from this directory with an Android emulator or iOS
simulator selected. The example uses four tabs with custom colors, icons,
labels and a badge. On Android it opts into a side rail at 600dp smallest
screen width. Open a detail page to try the native back button, or open the
popup to see how the bars behave while a modal is shown.

For an arm64 iOS simulator build on Xcode 27.2, run `flutter pub get` and
`flutter build ios --simulator --debug --config-only` to prepare the
workspace. Then select the simulator in Xcode or pass its identifier to
`xcodebuild`:

```sh
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

To run the native tab and back-button smoke test, use the same command with
`-parallel-testing-enabled NO -only-testing:RunnerUITests test` in place of
`build`.
