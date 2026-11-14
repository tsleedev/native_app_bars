# native_app_bars

Real OS top bars and tab bars for Flutter apps — `UINavigationBar` / `UITabBar`
on iOS, `MaterialToolbar` / `BottomNavigationView` / `NavigationRailView` on Android — or Flutter
widgets drawn from the **same description**, selectable per platform and per bar.

Licensed under the [MIT License](LICENSE). Third-party components retain
their own terms as listed in [Third-party notices](THIRD_PARTY_NOTICES.md).

## Why

- **One API, two renderers.** Describe a page's top bar and a shell's tab bar
  once. Each platform and each bar can be `ChromeRenderer.native` or
  `ChromeRenderer.flutter`, and you can switch at runtime.
- **The Flutter view is attached once.** On iOS the `FlutterViewController` is
  the child of a single host controller. The top bar belongs to a real
  `UINavigationController` in a sibling chrome layer (so UIKit lays it out:
  safe area, iPhone Duo system rail, vertical bar items), and the tab bar is a
  standalone `UITabBar` sibling. On Android the bars are sibling views of the
  `FlutterView`. Switching tabs never re-parents Flutter.
- **Dart owns selection.** Native tabs only *request* a selection; your
  `onSelect` decides. If you don't change state, nothing moves, and this behaves
  the same on iOS and Android.
- **Input is not lost to rebuilds, and stale input is not replayed.** Native
  events carry `{ownerToken, routeSession, semanticRevision, id}`. Dart accepts
  an event only if the owner and session match the bar currently shown and the
  id is enabled in the current description. A rebuild alone never invalidates
  input. A late `back`/`save` from a previous page never runs on the new page.

## Install

Add a Git dependency to the consuming app's `pubspec.yaml` once the
repository has a published commit or release tag.

```yaml
dependencies:
  native_app_bars:
    git:
      url: https://github.com/tsleedev/native_app_bars.git
      ref: "<published-commit-sha-or-release-tag>"
```

Replace the placeholder with the full SHA of a published commit for a
reproducible pin, or with a published release tag. You can find these refs
in the repository's commit history and tags. Then run `flutter pub get`.
For a local checkout, use a path dependency pointing at its package root.

## Install the host

**Android:** nothing to do. The plugin adds the native bars to your Activity
automatically (`FlutterActivity` or `FlutterFragmentActivity`).

Apps that use the Dart descriptors with their own renderer can disable the
overlay for a specific activity. Add this inside that activity's manifest
entry:

```xml
<meta-data android:name="dev.nativechrome.overlayEnabled" android:value="false" />
```

The activity keeps its existing view hierarchy. If it uses the package's
Flutter widgets, they use the Flutter renderer.

An Android host that already owns its toolbar slot can use
`EmbeddedNativeTopBar` with overlay installation disabled. Pass the existing
bar, toolbar content, and the host's effective insets to `show`. The package
waits for the replacement's first laid-out frame before hiding the existing
bar. Observe that swap with `onVisibilityChanged`. Read the displayed
toolbar's bottom with `bottomIn` in the coordinate space of your content view.
Consume that geometry once in the host. Call `hide` when the route loses its
slot, and `close` when disposing it. A paused activity automatically restores
the existing bar. The host remains responsible for route and modal ownership.

**iOS:** wrap the Flutter view controller once at launch.

The [standalone example](example/ios/Runner/AppDelegate.swift) registers
plugins through `FlutterImplicitEngineDelegate` and installs the host after
`FlutterSceneDelegate.scene(_:willConnectTo:options:)`. Its
[Info.plist](example/ios/Runner/Info.plist) selects that scene delegate.
For an existing app with a pre-scene lifecycle, call
`NativeChromeHost.install(in: window)` after
`super.application(_:didFinishLaunchingWithOptions:)`.

If the host is not installed, bars fall back to the Flutter renderer, and
`NativeChrome.of(context).diagnostics.hostIssue` explains why.

An iOS host that already manages a `UINavigationItem` can create a text
action with `NativeChromeBarButton.text`. Call it on the main actor. The host
owns the item, layout, enabled state, and current route's action callback.

### Tabs on an existing native host

On Android, construct `NativeChromeBottomMenu` with your configured Material
`BottomNavigationView` and the selection callback. Use unique, nonzero menu
IDs. The binder owns its items and both selection listeners. Use `setItems`
for labels and icons, `update` for enabled state and additional accessibility
text, and `select` to confirm a selection without dispatching the callback.
With the same IDs in the same order, updates keep the existing menu items and
badge objects. If you change the IDs or order, reapply each item's badge and
enabled state after `setItems`. Call `close` before disposing the host. Keep the
Material dependency, colors, dimensions, insets, and bar visibility in the app.

On iOS, create `NativeChromeManagedTabs` for an existing `UITabBarController`
on the main actor. Use `makeItem` to create UIKit tab items and `install` to
assign the child controllers. Call `confirm` with the current app selection
to bring UIKit into sync. Supply a preparation closure to move existing
content before the confirmed index changes. The host continues to own the
delegate, navigation stacks, appearance, and popup behavior.

### Top bars and segments on an existing native host

Use `NativeChromeNavigationPresentation.update` on the iOS main actor
with the host's existing navigation item and bar. Supply the title, custom
view, leading item, trailing items and interaction state. Standard placement
uses UIKit's Back action and trailing buttons. Pinned placement uses the
UIKit pinned trailing group and requests its compression preference on iOS
27.1 and later. UIKit decides presentation for the active layout. Switching
placement clears the previous Back and button groups. The host retains its
navigation stacks, appearance, modal handling and insets.

On Android, `NativeChromeToolbar` configures the content of an existing
framework Toolbar. It applies titles, Up and menu state, while the host
provides any custom action views or icons. `NativeChromeActionBar` works
with a framework ActionBar attached to the existing Toolbar. Keep the Activity's
usual options menu lifecycle and validate callbacks against the active route.

Use `NativeChromeSegments` on an existing UIKit segmented control or
`NativeChromeTabLayout` on an existing Android Material TabLayout.
Programmatic selection is silent for the Android binder's own callback. Keep
system styling, the callbacks' route checks and the view geometry in the app.
Close the Android binder when the control leaves its host.

## Use

Set `uses-material-design: true` in the consuming app when using Flutter's
Material icons. Run the [standalone example](example/README.md) to try
the native bars with four destinations.

Wrap the navigator in `NativeChrome` using `MaterialApp.builder` and put
`NativeChromeNavigatorObserver` on each navigator that owns chrome. Use
`NativeChromeScaffold` with `topBar`, `tabBar` or both. The example's
[main.dart](example/lib/main.dart) shows the complete setup and a detail
route with an implied back action.

### Android native tab customization

| Control | API and behavior |
|---|---|
| Background | `NativeChrome.appearance.backgroundColor` sets the bottom bar and rail background. The default is the Flutter theme's `ColorScheme.surfaceContainer`. |
| Selected / unselected content | `foregroundColor` and `unselectedColor` set both icons and labels. The defaults are `onSurface` and `onSurfaceVariant`. Android resolves the selected color from foreground first. |
| Active indicator | `indicatorColor`, defaulting to `secondaryContainer`. |
| Destination content | `NativeTabItem.label`, `icon`, optional `selectedIcon`, `badge`, `enabled` and `accessibilityValue`. Use two to five destinations with stable IDs. Android uses the Flutter glyph for each icon. A badge can be a dot (empty string), a number, or short text. |
| Label visibility | All destination labels are shown on the bottom bar and rail. Material controls their layout and typography. |
| Large-screen placement | Opt in with `NativeTabBar.largeScreenRail`. Android uses a start-edge rail at a smallest screen width of at least 600dp and insets the Flutter app beside it. iOS and the Flutter renderer keep a bottom bar. |
| Selection | `selectedId` is owned by Dart. Update it in `onSelect` to accept a tap. `onReselect` handles taps on the selected tab. |

The appearance colors apply at the root and some are shared with the top
bar. Native Material manages icon size, label typography, indicator shape,
spacing and bar height. For full control of the layout or label visibility
policy, select the Flutter tab renderer and provide `flutterTabBarBuilder`.

### Choosing renderers

| Need | Config |
|---|---|
| Everything native (default) | `NativeChromeConfig()` |
| iOS native top bar, branded Flutter tab bar, Android all Flutter | `NativeChromeConfig(ios: NativeChromePlatformConfig(tabBar: ChromeRenderer.flutter), android: NativeChromePlatformConfig.allFlutter())` plus `flutterTabBarBuilder` |
| Everything Flutter | `NativeChromeConfig.allFlutter()` |

The config is a widget argument, so changing it takes effect on the next frame.
`flutterTopBarBuilder` and `flutterTabBarBuilder` let you replace the default
Material `AppBar` / `NavigationBar` with your own design.

A custom top bar builder receives a `NativeTopBarRenderContext` and must run
actions through `bar.invoke(action)`. That applies the same busy rule as the
native bar: a Future-returning action blocks repeats until it completes, also
across a renderer switch. The builder must also honour `bar.presentation`
(`transparent`: no background). `hidden` pages get no app bar with any
renderer.

### Your own Scaffold

Pages that need `Scaffold` options `NativeChromeScaffold` does not forward
(bottom sheets, drawers, `PopScope` around a custom body) use
`NativeChromeAppBar` as the app bar:

```dart
Scaffold(
  appBar: NativeChromeAppBar(
    bar: NativeTopBar(title: 'Edit', actions: [...]),
    // Optional: your own Flutter bar when the Flutter renderer is used.
    flutterBuilder: (context, bar) => AppBar(title: Text(bar.title)),
  ),
  body: ...,
);
```

It registers the page's bar exactly like `NativeChromeScaffold.topBar`.
Native: an empty slot as tall as the native bar. Flutter: your builder (or
the default `AppBar`) at its own preferred height. `hidden`: a zero-height
slot (Scaffold still removes the body's top padding, as with any app bar).
`preferredSize` is an upper bound (`NativeChromeAppBar.maxExtent`); Scaffold
places the body below the height actually laid out.

### Top bar options

| Option | iOS native | Android native | Flutter (default AppBar) |
|---|---|---|---|
| `backgroundColor` / `foregroundColor` (per bar) | bar background, title and item tint | toolbar background, title, icons, text actions | AppBar colours |
| `titleAlignment: platform / leading / expandedLeading` | centred title / title as a leading item (headline / title2) | start title (20 / 22 sp) | `centerTitle` / start / `titleLarge` |
| `titleAction` (tappable title, its `icon`, `loading`) | title button; icon after a centred title, before a leading one; spinner while loading | same order; spinner while loading | same order; spinner while loading |
| `NativeBarAction.style: icon / text / done` | icon item / plain text / `.done` | icon / text / bold text (leading too) | IconButton / TextButton / bold |
| `NativeBarAction.loading` | spinner, input rejected | spinner, input rejected | spinner, input rejected |
| `NativeBarAction.badge` (icon actions) | not shown | Material badge on the item; label kept for TalkBack | `Badge` on the icon |
| `pinFirstAction` (opt-in) | first action in `pinnedTrailingGroup` (trailing edge, kept in compact bars) | ignored | ignored |
| `opacity` (default 1) | native chrome + popup dim faded as one group, including rail controls | top container + dim faded as one group | package wraps the default/custom builder once |

`NativeTabBar.largeScreenRail` (Android): at a smallest screen width of 600dp or more the native tab bar is a side rail on the start edge instead of the bottom bar; `NativeChrome` insets the whole app beside it (`geometry.tabRailWidth`), so pages, dialogs, sheets, menus and snack bars start at the rail edge. iOS and the Flutter renderer keep the bottom bar. Tab labels are always shown on every renderer.

`opacity` is visual only: finite values clamp to 0–1; NaN and either infinity
use 1. The default 1 is omitted from protocol-2 wire messages, so default
consumers keep their existing wire. Opt-in fade requires matching updated native
hosts; older hosts can ignore the optional field. Zero keeps the bar slot,
owner/session and explicit input/accessibility policy; `hidden` removes the slot.
Photo drag blocking and popup suspension remain separate policies. Custom Flutter
builders receive the description and are wrapped by the package: do not apply
`bar.opacity` again. Native outgoing snapshots preserve the outgoing composition
and never reuse the incoming opacity or dim.

On iOS 26+ the bar items sit on system glass, and `UINavigationBar.tintColor`
no longer colours their content (measured on iOS 27.0 against a pure UIKit
control). The host therefore applies the foreground to each item
(`UIBarButtonItem.tintColor`, spinner colour, title button colour). A
per-bar `backgroundColor` also sets that bar's light/dark style from its
luminance, so the glass platters match the background.

**Title space (iOS).** A tappable title (`titleAction`) is a title *view*.
When the leading item and actions leave no room for it, iOS drops a title
view entirely (a plain `title` is truncated instead); a pure UIKit bar
behaves the same. On a 402 pt wide iPhone, a text leading plus three text
actions leaves no room. Keep a title action to at most one or two actions on
compact widths, or use a plain title. The Flutter renderer always shows the
title (truncated if needed).

`NativeTabItem.accessibilityValue` (optional) is read with the tab instead of
the badge, for example the exact count when the badge shows `99+`.

`actions` are listed in visual order (leading → trailing edge) and keep that
order unless `pinFirstAction` is set. A loading action is disabled
(`isEnabled` is false). Action ids must be unique within a bar (leading,
title action and actions share one id space).

### Geometry for app overlays (iOS)

`NativeChrome.of(context).geometry` adds:

- `occlusionSupported` / `occlusionRegions`: active system occlusion regions
  (iOS 27.1 `reservedRegions(kind: .occlusion)`), in logical pixels.
  Empty and unsupported before iOS 27.1 and on Android.
- `hiddenActionSlot`: while the current page's bar is `hidden`, where a
  trailing action would sit if the bar were shown. Measured asynchronously
  after layout (null until measured, re-measured when size, safe area,
  direction or occlusion regions change, null when the bar is visible or a
  transition runs).

Native hooks on `NativeChromeHostViewController`: `onTopBarHiddenChange`
(called synchronously in the update that hides or shows the bar; do not
apply chrome state from inside it) and `hiddenActionSlotRect`. An app can
cover the frame gap with its own view at that rect until its Flutter overlay
has painted. `NativeChromeController.transitionActive` tells Flutter overlays
when a bar transition is running.

### Versions

Protocol 2 gained optional fields only. An older native host ignores them
(titles, styles, pinning, geometry extensions), so ship the Dart package and
its native code together (one package version per app build).

### Connections

Each `NativeChrome` attach opens a new connection (lease) to the native host.
Native bars are used only after the host confirms it (protocol 2 with the
lease echoed). If the plugin is missing, the protocol mismatches or the host
rejects the connection, the bars fall back to Flutter, and
`diagnostics.hostIssue` says why.
Replacing the controller shows the new state immediately, and input from the
previous connection is rejected. Removing `NativeChrome` clears the native bars
so touches reach Flutter again.

### Popups, overlays and the keyboard

Applications that resolve several black popup barriers may set
`NativeChrome(popupOpacity: value, ...)` on the root connection. `null` keeps
legacy automatic top-popup dimming; finite values clamp to 0..1, and non-finite
values use the null default. Explicit zero keeps modal input/AX suspension while
painting transparent black. A value alone never creates suspension or a modal,
and lifecycle suspension alone never creates popup paint. The resolved scalar
uses the existing native `dim` map with duration zero because the caller already
animates it. It adds no Flutter barrier and does not change owner/session stamps.
Root removal or controller replacement clears the previous override. The caller
must track the actual visible barrier stack, animation/reverse/completed lifetime
and unsupported-color fallback; this is not a foreground mask API.

- Add `NativeChromeNavigatorObserver` to every navigator that hosts pages with
  bars (the root navigator and nested tab navigators). While a dialog or sheet
  is open, the bars stay visible but native input is suspended. Touches on the
  bars then reach Flutter's barrier, and the bars are dimmed with the barrier
  colour (`dimDuringSuspension: false` disables the dim).
- Wrap app overlays that are not routes (ads, custom layers) in
  `NativeChromeSuspension(active: ..., child: ...)`.
- The tab bar hides while the software keyboard is visible
  (`hideTabBarWhenKeyboardVisible`).
- While suspended, the native bars are also hidden from accessibility
  (VoiceOver/TalkBack stay in the popup) and restored afterwards.
- Leaving the resumed app state (inactive, hidden, paused) renews the bars'
  stamps at once: native input queued before it is rejected, input while not
  resumed counts as suspended, and the first tap after resume is accepted.

### Icons

`NativeChromeIcon(Icons.home, iosSymbol: 'house')`: iOS uses the SF Symbol.
Android (and iOS without a symbol) gets the Flutter glyph, rasterised and
tinted natively. No icon files are bundled.

### Diagnostics

`NativeChrome.of(context).diagnostics` counts accepted and rejected native
events by reason (`ownerMismatch`, `sessionMismatch`, `suspended`,
`transition`, `disabled`, `busy`, …). Debug builds log them with the
`[native_chrome]` tag.

### Android action overflow

Set `NativeBarAction.androidOverflowIfRoom` on a trailing top-bar action to
let Android move it into the toolbar menu when space is limited. Actions
stay in the bar by default. Loading actions, iOS, and the Flutter renderer
keep their existing placement. While the Android menu has focus, it accepts
its own selections only while the host Activity is resumed. Pausing the
Activity dismisses the menu.

## Support

| Platform | Declared requirement | Verified for this candidate |
|---|---|---|
| Flutter | Flutter 3.38.1 and Dart 3.10 or later within the package SDK constraints | Flutter 3.38.10 and Dart 3.10.9. Flutter 3.38.1 was not tested. |
| Android | API 26 supported (library minSdk 24), compile SDK 36 | API 35 arm64 emulator and compile SDK 36. |
| iOS runtime | Deployment target iOS 16.0 | iOS 27.2 on an iPhone 17 simulator. iOS 16.0 was not tested. |
| iOS build SDK | iOS 27.1 SDK or newer for the UIKit declarations used by the plugin | Xcode 27.2 with the iOS 27.2 SDK, arm64 simulator build. The iOS 27.1 SDK was not tested. |

The Swift host uses UIKit APIs introduced in iOS 27.1, including
`axisBehavior`, `verticalBarCompressionBehavior` and `reservedRegions`.
The host checks availability at runtime. The build SDK must still declare
those APIs.

Not supported in v0: multiple Flutter engines or windows per process,
interactive (finger-driven) Android predictive-back bar animation, more than
five tabs.

Known limit (iOS, iPhone Duo / system rail layouts): the native tab bar is a
standalone `UITabBar`, so it stays a horizontal bar at the bottom and does not
move into the system rail the way a `UITabBarController` tab bar does. Top bar
items do move into the rail (the top bar is owned by a
`UINavigationController`).
