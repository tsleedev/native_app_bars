## 0.1.0-dev.8

- iOS leading icon actions can show an optional original-color avatar from bounded PNG bytes, with the configured icon as fallback.
- iOS icon actions can opt into the existing action badge and provide a separate accessibility value. The value is available on supported iOS versions, and the visible native badge requires iOS 26 or later. Actions without the opt-in retain their previous behavior.

## 0.1.0-dev.7

- Apply titles, actions, and interaction state to existing UIKit navigation bars and Android toolbars. Hosts keep ownership of their views, layout, lifecycle, and navigation.
- Synchronize selection and labels on existing UIKit segmented controls and Android Material tab layouts.

## 0.1.0-dev.6

- The GitHub repository and Flutter package are now named `native_app_bars`. Change the Git URL and dependency key, and import `package:native_app_bars/native_app_bars.dart`. iOS hosts that import the pod directly use `import native_app_bars`. The native plugin classes, Android namespace, and channel protocol retain their existing identities.

## 0.1.0-dev.5

- Android hosts can use `NativeChromeBottomMenu` to create and update the items of an existing Material `BottomNavigationView`, handle selection, and keep their configured styling and layout.
- iOS hosts can use `NativeChromeManagedTabs` to create UIKit tab items and synchronize a host-owned `UITabBarController` while keeping its navigation stacks and delegate.

## 0.1.0-dev.4

- Android hosts can present a package toolbar in their existing slot with `EmbeddedNativeTopBar`. The existing bar remains available until the replacement has laid out. Pausing the activity or detaching the slot restores the existing bar.
- iOS hosts can create a package text action with `NativeChromeBarButton.text` for an existing navigation item and keep their current view-controller hierarchy.

## 0.1.0-dev.3

- Android trailing top-bar actions can opt into the native toolbar overflow with `NativeBarAction.androidOverflowIfRoom`. An overflow selection can run while that menu holds window focus and the Activity remains resumed. Pausing the Activity closes its menu.

## 0.1.0-dev.2

- Android activities can opt out of the package overlay with `dev.nativechrome.overlayEnabled=false`. The setting is read from the concrete activity, including launches through aliases. Activities without the setting still install the overlay automatically.
- Android clears the previous activity's chrome state and geometry when switching hosts. Flutter renegotiates the connection if a plugin is recreated while its Dart isolate is still running, and ignores delayed events and replies from the old host.

## 0.1.0-dev.1

- iOS push and back transitions follow the Cupertino page curve for programmatic moves and linear progress during gestures. Push snapshots clip to the outgoing page. Routes with chrome on one side still animate, and removing or replacing the moving route ends synchronization.

- `NativeTabBar.largeScreenRail` (optional protocol-2 field, Android only): on large screens (smallest width >= 600dp) the Android host shows a side navigation rail on the start edge instead of the bottom bar; geometry adds optional `tabBarPlacement`/`tabRailWidth` and `NativeChrome` reserves the rail width once. iOS and the Flutter renderer keep the bottom bar.
- While the Android rail is shown, the whole app below `NativeChrome` starts beside it (MediaQuery size/insets reduced, OS display features translated), so root dialogs, sheets, menus, pickers and snack bars never sit under the rail; crossing 600dp does not remount the app. While a popup is open, a tap on the rail acts like a tap on its barrier (dismissible popups close; no tab selection).
- Android tab bars (bottom bar and rail) always show every label, like iOS and the Flutter `NavigationBar` (now explicitly `alwaysShow`).
- Android top bar badges: attachment is cancelled on menu rebuild/clear and checked against the current item; menu ids are new per rebuild.
- `NativeBarAction.badge` (optional protocol-2 field, sent only when set on an icon action): an empty string shows a dot, other text (for example `3` or `99+`) is shown as given. Android draws a Material badge on the toolbar item and keeps the action label as its accessibility description; the Flutter renderer wraps the icon in a `Badge`; the iOS host does not show it. Put the meaning in the label too.
- `NativeTopBar.opacity` (optional protocol-2 field, default 1 omitted): finite clamp with non-finite fallback 1; visual-only native/Flutter fade without changing bar geometry, ownership, input or AX policy. Solid popup dim composes inside the native top paint group before fade; outgoing captures retain their own opacity/dim. Custom Flutter builders are faded once by the package. Opt-in native fade requires updated hosts.

- `NativeTabItem.accessibilityValue` (optional, additive): read with the tab instead of the badge text (for example the exact count behind a `99+` badge). Optional protocol 2 field, sent only when set; iOS `UITabBarItem.accessibilityValue`, Android content description, Flutter renderer semantics value.
- Lifecycle: leaving the resumed state renews the shown bars' route sessions and sends them at once, so native events queued before the change are rejected (`sessionMismatch`) and input while not resumed counts as `suspended`; the first tap after resume is accepted.
- Popup suspension also hides the native bars from accessibility (iOS top bar, Duo rail items and tab bar; Android toolbar and bottom navigation) and restores them when it ends or the connection is cleared.
- iOS (iPhone Duo system rail): top bar items that UIKit moves into the rail now leave with the outgoing bar during a transition (a chrome-layer snapshot of the rail items), and a solid bar's rail items are faded once under a popup (the dim layer covers the bar strip only). Layouts without rail items (iPhone) do not run this code.
- `NativeChromeAppBar`: the top bar for an app's own `Scaffold` (`appBar:`), with the same owner, busy and renderer rules as `NativeChromeScaffold`.
- Top bar extensions (wire fields added to protocol 2): per-bar `backgroundColor`/`foregroundColor`, `titleAlignment` (`platform`, `leading`, `expandedLeading`), tappable `titleAction` (icon and loading in every renderer), `NativeBarAction.loading` and `.style` (`icon`, `text`, `done`; leading too on Android), and opt-in `pinFirstAction` (iOS). Actions keep their given order by default.
- iOS geometry: `occlusionSupported`/`occlusionRegions` (iOS 27.1 reserved regions) and `hiddenActionSlot` with the host hooks `onTopBarHiddenChange` / `hiddenActionSlotRect`. `NativeChromeController.transitionActive`.

- Channel receiving is taken on attach (not on construction) and released only by the current receiver, so external controllers can be reused (A → B → A) and idle controllers never steal input.
- Lost host connections renegotiate a new lease (request ids and revisions restart together); stale `hostReady` races do not reset.
- Protocol negotiation is verified (protocol 2 and lease echo); mismatches, attach/update rejections and missing plugins fall back to the Flutter renderer with a diagnostics reason and no unhandled errors. Nothing is sent before the host confirms the connection.

- Protocol 2: connection leases on attach/update/transition/event, `detach`, and per-lease unique request ids. Controller replacement shows the new state at once; old-lease input, duplicate requests and stale detaches are rejected.
- One action dispatcher for native and Flutter renderers (default, custom builder via `NativeTopBarRenderContext.invoke`, host-less fallback), so busy holds across renderer switches.
- `hidden` presentation removes the app bar slot for every renderer; `transparent` is honoured by the Flutter renderer.
- Removing `NativeChrome` (or releasing its controller) clears native bars.

- Native top bar and tab bar hosts: iOS top bar owned by a `UINavigationController` in a chrome layer and a standalone `UITabBar`, both siblings of a once-attached `FlutterViewController` (the tab bar does not join an iPhone Duo system rail — known limit); Android `MaterialToolbar`/`BottomNavigationView` siblings of the `FlutterView`.
- One description rendered natively or by Flutter; per-platform and per-bar renderer selection with runtime switching and automatic fallback.
- Dart-owned tab selection; native controls only request (same semantics on iOS and Android).
- Owner/session-checked native events; content-only revisions so rebuilds never drop input; observable rejections.
- Popup suspension with barrier dim, `NativeChromeSuspension`, keyboard-aware tab bar, transition sync, lifecycle resync.
- Native bar items are rebuilt only when their content changes (prevents lost taps during unrelated updates).

- Add optional root `NativeChrome.popupOpacity` for app-resolved black popup
  composition, retaining null/default wire behavior and independent input/AX
  suspension; no native protocol or host change.
