import 'package:flutter/material.dart';

/// Which renderer draws a bar.
enum ChromeRenderer {
  /// The operating system control: `UINavigationBar`/`UITabBar` on iOS,
  /// `MaterialToolbar`/`BottomNavigationView` on Android.
  native,

  /// A Flutter widget built from the same descriptor (Material `AppBar` /
  /// `NavigationBar` by default, or the app's own builder).
  flutter,
}

/// Renderer selection for one platform. Top bar and tab bar are chosen
/// independently because real apps mix them (for example a native iOS top bar
/// with a branded Flutter tab bar).
@immutable
class NativeChromePlatformConfig {
  const NativeChromePlatformConfig({
    this.topBar = ChromeRenderer.native,
    this.tabBar = ChromeRenderer.native,
  });

  const NativeChromePlatformConfig.allNative()
    : topBar = ChromeRenderer.native,
      tabBar = ChromeRenderer.native;

  const NativeChromePlatformConfig.allFlutter()
    : topBar = ChromeRenderer.flutter,
      tabBar = ChromeRenderer.flutter;

  final ChromeRenderer topBar;
  final ChromeRenderer tabBar;

  NativeChromePlatformConfig copyWith({
    ChromeRenderer? topBar,
    ChromeRenderer? tabBar,
  }) => NativeChromePlatformConfig(
    topBar: topBar ?? this.topBar,
    tabBar: tabBar ?? this.tabBar,
  );

  @override
  bool operator ==(Object other) =>
      other is NativeChromePlatformConfig &&
      other.topBar == topBar &&
      other.tabBar == tabBar;

  @override
  int get hashCode => Object.hash(topBar, tabBar);

  @override
  String toString() => 'NativeChromePlatformConfig(top: $topBar, tab: $tabBar)';
}

/// Package configuration. The default renders both bars natively on both
/// platforms; any platform without an installed native host (web, desktop,
/// tests, or an app that did not install the iOS host) automatically uses the
/// Flutter renderer.
@immutable
class NativeChromeConfig {
  const NativeChromeConfig({
    this.ios = const NativeChromePlatformConfig(),
    this.android = const NativeChromePlatformConfig(),
    this.hideTabBarWhenKeyboardVisible = true,
    this.dimDuringSuspension = true,
    this.syncTransitions = true,
  });

  const NativeChromeConfig.allFlutter()
    : ios = const NativeChromePlatformConfig.allFlutter(),
      android = const NativeChromePlatformConfig.allFlutter(),
      hideTabBarWhenKeyboardVisible = true,
      dimDuringSuspension = true,
      syncTransitions = true;

  final NativeChromePlatformConfig ios;
  final NativeChromePlatformConfig android;

  /// Hide the tab bar (native or Flutter) while the software keyboard is up.
  final bool hideTabBarWhenKeyboardVisible;

  /// Dim native bars with the popup barrier colour while input is suspended.
  /// Apps that paint their own mask over native bars (see `geometry`) set this
  /// to false.
  final bool dimDuringSuspension;

  /// Drive native top bar transitions from Flutter page route animations.
  final bool syncTransitions;

  NativeChromePlatformConfig forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => ios,
        TargetPlatform.android => android,
        _ => const NativeChromePlatformConfig.allFlutter(),
      };

  NativeChromeConfig copyWith({
    NativeChromePlatformConfig? ios,
    NativeChromePlatformConfig? android,
    bool? hideTabBarWhenKeyboardVisible,
    bool? dimDuringSuspension,
    bool? syncTransitions,
  }) => NativeChromeConfig(
    ios: ios ?? this.ios,
    android: android ?? this.android,
    hideTabBarWhenKeyboardVisible:
        hideTabBarWhenKeyboardVisible ?? this.hideTabBarWhenKeyboardVisible,
    dimDuringSuspension: dimDuringSuspension ?? this.dimDuringSuspension,
    syncTransitions: syncTransitions ?? this.syncTransitions,
  );

  @override
  bool operator ==(Object other) =>
      other is NativeChromeConfig &&
      other.ios == ios &&
      other.android == android &&
      other.hideTabBarWhenKeyboardVisible == hideTabBarWhenKeyboardVisible &&
      other.dimDuringSuspension == dimDuringSuspension &&
      other.syncTransitions == syncTransitions;

  @override
  int get hashCode => Object.hash(
    ios,
    android,
    hideTabBarWhenKeyboardVisible,
    dimDuringSuspension,
    syncTransitions,
  );
}

/// Colours applied to native bars. `null` keeps the platform default.
///
/// On iOS the default keeps the system bar material and only applies the tint
/// and light/dark style. On Android the default is derived from the Flutter
/// [ColorScheme] so Material 3 native views match the app.
@immutable
class NativeChromeAppearance {
  const NativeChromeAppearance({
    this.brightness,
    this.backgroundColor,
    this.foregroundColor,
    this.tintColor,
    this.unselectedColor,
    this.indicatorColor,
  });

  final Brightness? brightness;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Color? tintColor;
  final Color? unselectedColor;
  final Color? indicatorColor;

  /// Resolves app overrides against the current theme for [platform].
  static Map<String, Object?> resolve(
    NativeChromeAppearance? override,
    ThemeData theme,
    TargetPlatform platform,
  ) {
    final scheme = theme.colorScheme;
    final android = platform == TargetPlatform.android;
    int? argb(Color? c) => c?.toARGB32();
    return <String, Object?>{
      'brightness':
          (override?.brightness ?? theme.brightness) == Brightness.dark
          ? 'dark'
          : 'light',
      'background': argb(
        override?.backgroundColor ?? (android ? scheme.surfaceContainer : null),
      ),
      'foreground': argb(
        override?.foregroundColor ?? (android ? scheme.onSurface : null),
      ),
      'tint': argb(override?.tintColor ?? scheme.primary),
      'unselected': argb(
        override?.unselectedColor ?? (android ? scheme.onSurfaceVariant : null),
      ),
      'indicator': argb(
        override?.indicatorColor ??
            (android ? scheme.secondaryContainer : null),
      ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is NativeChromeAppearance &&
      other.brightness == brightness &&
      other.backgroundColor == backgroundColor &&
      other.foregroundColor == foregroundColor &&
      other.tintColor == tintColor &&
      other.unselectedColor == unselectedColor &&
      other.indicatorColor == indicatorColor;

  @override
  int get hashCode => Object.hash(
    brightness,
    backgroundColor,
    foregroundColor,
    tintColor,
    unselectedColor,
    indicatorColor,
  );
}
