import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// An icon usable by both renderers.
///
/// iOS native bars use [iosSymbol] (an SF Symbol name) when given. Everywhere
/// else (Android native bars, iOS without a symbol, and the Flutter renderer)
/// the [icon] glyph is used. Native platforms receive the glyph rasterised by
/// Flutter as a template image, so no icon files are bundled or copied.
@immutable
class NativeChromeIcon {
  const NativeChromeIcon(this.icon, {this.iosSymbol});

  final IconData icon;
  final String? iosSymbol;

  /// Stable cache key for the rasterised glyph.
  String get key =>
      '${icon.fontFamily ?? ''}/${icon.fontPackage ?? ''}/${icon.codePoint}';

  Map<String, Object?> toWire() => <String, Object?>{
    'key': key,
    if (iosSymbol != null) 'iosSymbol': iosSymbol,
  };

  @override
  bool operator ==(Object other) =>
      other is NativeChromeIcon &&
      other.icon == icon &&
      other.iosSymbol == iosSymbol;

  @override
  int get hashCode => Object.hash(icon, iosSymbol);
}

/// Common icons with matching SF Symbols.
abstract final class NativeChromeIcons {
  static const back = NativeChromeIcon(
    Icons.arrow_back,
    iosSymbol: 'chevron.backward',
  );
  static const close = NativeChromeIcon(Icons.close, iosSymbol: 'xmark');
  static const add = NativeChromeIcon(Icons.add, iosSymbol: 'plus');
  static const save = NativeChromeIcon(Icons.check, iosSymbol: 'checkmark');
  static const edit = NativeChromeIcon(Icons.edit, iosSymbol: 'pencil');
  static const delete = NativeChromeIcon(Icons.delete, iosSymbol: 'trash');
  static const share = NativeChromeIcon(
    Icons.share,
    iosSymbol: 'square.and.arrow.up',
  );
  static const search = NativeChromeIcon(
    Icons.search,
    iosSymbol: 'magnifyingglass',
  );
  static const settings = NativeChromeIcon(
    Icons.settings,
    iosSymbol: 'gearshape',
  );
  static const more = NativeChromeIcon(Icons.more_horiz, iosSymbol: 'ellipsis');
  static const home = NativeChromeIcon(Icons.home, iosSymbol: 'house');
  static const refresh = NativeChromeIcon(
    Icons.refresh,
    iosSymbol: 'arrow.clockwise',
  );
}

/// Local PNG for the leading action on the iOS native top bar.
///
/// The host accepts images no larger than 128×128. Missing, invalid or
/// unsupported images use the action's regular icon. No network lookup occurs.
final class NativeChromeIOSAvatar {
  NativeChromeIOSAvatar(Uint8List png) : png = _copy(png);

  final Uint8List png;

  static Uint8List _copy(Uint8List source) {
    if (source.isEmpty || source.length > 64 * 1024) {
      throw ArgumentError('Avatar PNG must contain 1–65536 bytes.');
    }
    return Uint8List.fromList(source).asUnmodifiableView();
  }
}

/// Callback for bar actions. Returning a [Future] marks the owning bar busy
/// until it completes; further actions from that bar are rejected meanwhile.
typedef NativeChromeCallback = FutureOr<void> Function();

/// A button in a top bar.
/// How a top bar action is drawn.
enum NativeBarActionStyle {
  /// Icon button (falls back to text when there is no icon).
  icon,

  /// Plain text button.
  text,

  /// Emphasised text button (iOS `.done`, Android bold text).
  done,
}

@immutable
class NativeBarAction {
  const NativeBarAction({
    required this.id,
    required this.label,
    this.icon,
    this.onPressed,
    this.enabled = true,
    this.loading = false,
    this.style = NativeBarActionStyle.icon,
    this.badge,
    this.iosBadgeAccessibilityValue,
    this.iosAvatar,
    this.androidOverflowIfRoom = false,
  });

  /// Standard back button that pops the nearest navigator (Navigator 1 and 2).
  const NativeBarAction.back({this.onPressed, String? label})
    : id = 'back',
      label = label ?? 'Back',
      icon = NativeChromeIcons.back,
      enabled = true,
      loading = false,
      style = NativeBarActionStyle.icon,
      badge = null,
      iosBadgeAccessibilityValue = null,
      iosAvatar = null,
      androidOverflowIfRoom = false;

  /// Close button for modal pages.
  const NativeBarAction.close({this.onPressed, String? label})
    : id = 'close',
      label = label ?? 'Close',
      icon = NativeChromeIcons.close,
      enabled = true,
      loading = false,
      style = NativeBarActionStyle.icon,
      badge = null,
      iosBadgeAccessibilityValue = null,
      iosAvatar = null,
      androidOverflowIfRoom = false;

  /// Stable identifier. The same id must keep the same meaning within a page;
  /// change it when the action's meaning changes.
  final String id;

  /// Accessibility label, and the visible text when [icon] is null.
  final String label;
  final NativeChromeIcon? icon;
  final NativeChromeCallback? onPressed;
  final bool enabled;

  /// Shows a progress indicator instead of the button; not tappable.
  final bool loading;
  final NativeBarActionStyle style;

  /// Badge on an icon action (for example an unread count), with the same
  /// rules as [NativeTabItem.badge]: an empty string shows a dot, a number or
  /// short text (for example `99+`) is shown as given, null shows nothing.
  /// Put the meaning in [label] too (for example "Inbox, 3 unread"): the
  /// badge itself is visual. Optional wire field, sent only when set.
  /// Rendered by the Android host and the Flutter renderer. An iOS leading
  /// or trailing icon action opts in with [iosBadgeAccessibilityValue].
  final String? badge;

  /// Nonempty localized accessibility value that opts the iOS native icon
  /// action into [badge]. iOS 26+ also displays the badge visually.
  /// Omitting this value preserves the existing iOS behavior.
  final String? iosBadgeAccessibilityValue;

  /// Optional original-color image for an iOS native leading icon action.
  final NativeChromeIOSAvatar? iosAvatar;

  /// Lets the Android top toolbar move this trailing action into overflow
  /// when space is limited. Other renderers and loading actions are unchanged.
  final bool androidOverflowIfRoom;

  bool get isEnabled => enabled && !loading && onPressed != null;

  Map<String, Object?> toWire() => <String, Object?>{
    'id': id,
    'label': label,
    'icon': style == NativeBarActionStyle.icon ? icon?.toWire() : null,
    'enabled': isEnabled,
    'loading': loading,
    'style': style.name,
    'badge': ?(style == NativeBarActionStyle.icon ? badge : null),
    if (androidOverflowIfRoom && !loading) 'androidOverflowIfRoom': true,
  };
}

/// How the native top bar is presented for a page.
enum NativeTopBarPresentation {
  /// Opaque bar; content is laid out below it.
  opaque,

  /// Transparent bar drawn over content; content is still inset below it
  /// unless the page opts out with `extendBodyBehindTopBar`.
  transparent,

  /// No bar for this page (for example a full-screen hero). Apps can draw their
  /// own overlay using `NativeChrome.of(context).geometry`.
  hidden,
}

/// Top bar description. One description per page; the package shows the one
/// that belongs to the visible page.
/// Where the top bar title sits.
enum NativeTopBarTitleAlignment {
  /// Platform default (centered on iOS, start-aligned on Android).
  platform,

  /// Start-aligned, next to the leading action.
  leading,

  /// Start-aligned with a larger title font.
  expandedLeading,
}

@immutable
class NativeTopBar {
  const NativeTopBar({
    required this.title,
    this.leading,
    this.actions = const <NativeBarAction>[],
    this.automaticallyImplyBack = true,
    this.presentation = NativeTopBarPresentation.opaque,
    this.titleAlignment = NativeTopBarTitleAlignment.platform,
    this.titleAction,
    this.backgroundColor,
    this.foregroundColor,
    this.pinFirstAction = false,
    this.opacity = 1,
  });

  final String title;

  /// Visual alpha only; does not change ownership, input or accessibility.
  /// Non-finite values use 1; finite values are clamped to [0, 1].
  /// The default is omitted from the wire for older protocol-2 hosts.
  final double opacity;
  double get effectiveOpacity => opacity.isFinite ? opacity.clamp(0.0, 1.0) : 1;

  /// Makes the title tappable (for example a date picker). Its `label` is the
  /// accessibility label; the visible text is [title].
  final NativeBarAction? titleAction;
  final NativeTopBarTitleAlignment titleAlignment;

  /// Per-page bar colours; null uses `NativeChrome.appearance`.
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// Leading button. When null and [automaticallyImplyBack] is true, a back
  /// button is added if the page's navigator can pop.
  final NativeBarAction? leading;

  /// Trailing actions in visual order (leading → trailing edge), the same
  /// with every renderer.
  final List<NativeBarAction> actions;
  final bool automaticallyImplyBack;
  final NativeTopBarPresentation presentation;

  /// iOS only, opt-in: puts the first of [actions] in the navigation item's
  /// `pinnedTrailingGroup`, so it stays visible and sits at the trailing edge
  /// (after the other actions) in compact and vertical bars. Off by default,
  /// which keeps [actions] in their given order. Ignored by Android and by the
  /// Flutter renderer.
  final bool pinFirstAction;
}

/// One destination in a tab bar.
@immutable
class NativeTabItem {
  const NativeTabItem({
    required this.id,
    required this.label,
    required this.icon,
    this.selectedIcon,
    this.badge,
    this.enabled = true,
    this.accessibilityValue,
  });

  final String id;
  final String label;
  final NativeChromeIcon icon;
  final NativeChromeIcon? selectedIcon;

  /// Badge text. An empty string shows a dot; null shows nothing.
  final String? badge;
  final bool enabled;

  /// Optional accessibility value read with the tab (for example the exact
  /// count behind a capped `99+` badge). Null keeps the platform default
  /// (iOS/Android derive it from the badge). Optional wire field: a host that
  /// does not know it ignores it, and it is not sent when null.
  final String? accessibilityValue;

  Map<String, Object?> toWire() => <String, Object?>{
    'id': id,
    'label': label,
    'icon': icon.toWire(),
    'selectedIcon': selectedIcon?.toWire(),
    'badge': badge,
    'enabled': enabled,
    'accessibilityValue': ?accessibilityValue,
  };
}

/// Tab bar description. Selection is owned by the app: native controls only
/// *request* a change through [onSelect]; the bar shows [selectedId] as given.
/// Not calling setState in [onSelect] is how an app rejects a selection, and
/// it behaves the same on iOS and Android.
@immutable
class NativeTabBar {
  const NativeTabBar({
    required this.items,
    required this.selectedId,
    required this.onSelect,
    this.onReselect,
    this.largeScreenRail = false,
  }) : assert(items.length >= 2 && items.length <= 5);

  final List<NativeTabItem> items;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onReselect;

  /// Android native renderer only: on large screens (smallest screen width
  /// at least 600dp) the host shows a side navigation rail on the start edge
  /// instead of the bottom bar, and [NativeChrome] insets the whole app beside
  /// it (see [NativeChromeGeometry.tabRailWidth]). The iOS host and the
  /// Flutter renderer keep the bottom tab bar. Optional wire field, sent only
  /// when set.
  final bool largeScreenRail;
}
