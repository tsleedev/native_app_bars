import 'package:flutter/material.dart';

/// A segmented control drawn by Flutter: a surface track with the selected
/// segment as a filled pill. Use it where a platform tab strip does not fit,
/// for example Android segments that sit over a header blur.
///
/// Each segment's touch and accessibility target is the full track height,
/// at least [minTargetSize] (48dp, the Android minimum). The visible pill is
/// inset inside it, so controls stacked without a gap keep separate targets.
/// Labels may wrap to two lines at large text sizes.
///
/// Selection is ignored, and the segments are reported disabled, while:
/// - the app is not resumed (Android reports a window without focus as
///   inactive, for example while a framework popup menu is open),
/// - [active] is false,
/// - [routeIsActive] returns false for the enclosing route, or
/// - that route is not current, is offstage, or is still animating.
///
/// These are checked when building and again when a tap is delivered, so a
/// tap that lands after a change but before the next frame does not select.
/// [routeIsActive] is asked again at that moment because an app's route policy
/// may depend on state outside this route (outer navigators, closing
/// overlays) that does not rebuild this widget.
///
/// Selecting the current segment does not call [onChanged].
class NativeChromeSegmentedControl extends StatefulWidget {
  const NativeChromeSegmentedControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    this.active = true,
    this.routeIsActive,
    this.trackColor,
    this.selectedColor,
    this.foregroundColor,
    this.selectedForegroundColor,
    this.textStyle,
  });

  /// Minimum height of the track and of each segment's target.
  static const double minTargetSize = 48;

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// The owner's own activity (for example a hidden tab or an inactive
  /// chrome scope). False disables selection.
  final bool active;

  /// The app's route policy, asked with the enclosing route at build time and
  /// whenever a tap is delivered.
  final bool Function(Route<dynamic>? route)? routeIsActive;

  /// Defaults to [ColorScheme.surface].
  final Color? trackColor;

  /// Defaults to [ColorScheme.primary].
  final Color? selectedColor;

  /// Defaults to [ColorScheme.onSurface].
  final Color? foregroundColor;

  /// Defaults to [ColorScheme.onPrimary].
  final Color? selectedForegroundColor;

  /// Defaults to [TextTheme.labelLarge] at weight 600.
  final TextStyle? textStyle;

  @override
  State<NativeChromeSegmentedControl> createState() =>
      _NativeChromeSegmentedControlState();
}

class _NativeChromeSegmentedControlState
    extends State<NativeChromeSegmentedControl>
    with WidgetsBindingObserver {
  static const double _inset = 3;

  ModalRoute<Object?>? _route;

  bool get _enabled {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final route = _route;
    return mounted &&
        widget.active &&
        (widget.routeIsActive?.call(route) ?? true) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        (route == null ||
            (route.isCurrent &&
                !route.offstage &&
                (route.animation == null ||
                    route.animation!.status == AnimationStatus.completed)));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_routeChanged);
      _route = route;
      _route?.animation?.addStatusListener(_routeChanged);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() {});
  }

  void _routeChanged(AnimationStatus _) {
    if (mounted) setState(() {});
  }

  void _select(int index) {
    if (!_enabled || index == widget.selectedIndex) return;
    widget.onChanged(index);
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_routeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = widget.trackColor ?? scheme.surface;
    final pill = widget.selectedColor ?? scheme.primary;
    final onPill = widget.selectedForegroundColor ?? scheme.onPrimary;
    final text = widget.foregroundColor ?? scheme.onSurface;
    final style =
        widget.textStyle ??
        (theme.textTheme.labelLarge ?? const TextStyle(fontSize: 14)).copyWith(
          fontWeight: FontWeight.w600,
        );
    final enabled = _enabled;
    return ConstrainedBox(
      key: const ValueKey('native_chrome.segmentedControl'),
      constraints: const BoxConstraints(
        minHeight: NativeChromeSegmentedControl.minTargetSize,
      ),
      child: Material(
        color: track,
        borderRadius: BorderRadius.circular(10),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < widget.labels.length; index++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: index == widget.selectedIndex,
                    inMutuallyExclusiveGroup: true,
                    enabled: enabled,
                    child: InkWell(
                      onTap: enabled && index != widget.selectedIndex
                          ? () => _select(index)
                          : null,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(_inset),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: index == widget.selectedIndex
                                ? pill
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 7,
                            ),
                            child: Center(
                              child: Text(
                                widget.labels[index],
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.fade,
                                style: style.copyWith(
                                  color: index == widget.selectedIndex
                                      ? onPill
                                      : text,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
