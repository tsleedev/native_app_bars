import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Android: one blur behind a translucent host top bar and the fixed page
/// header that continues below it (segments, filters), so the document that
/// scrolls beneath both reads as under one surface, as on iOS.
///
/// Returns a [Positioned]; place it in a full-viewport [Stack] above the
/// document and below the header controls. It is paint-only: no pointer
/// input and no semantics.
///
/// - [bar] is the host bar in this Stack's coordinates (status region
///   included, so its top is normally 0).
/// - [bottom] is the bottom of the fixed page header; the blur covers
///   `max(bar.bottom, bottom)`.
/// - [tint] is the bar's own translucent surface. The host bar already paints
///   it over the bar part; this widget repeats it below the bar so bar and
///   header have no seam. Hosts report it from
///   `NativeChromeDocumentBackdrop.barTint` (Kotlin). When null, only the
///   blur is painted.
///
/// Only show it when the host confirms that its bar is translucent for this
/// document (API 26 hosts keep an opaque bar; see
/// `NativeChromeDocumentBackdrop.supported`). Otherwise keep the header above
/// the document.
class NativeChromeAndroidHeaderBackdrop extends StatelessWidget {
  const NativeChromeAndroidHeaderBackdrop({
    super.key,
    required this.bar,
    required this.bottom,
    this.tint,
  });

  final Rect bar;
  final double bottom;
  final Color? tint;

  /// Key of the tinted part below the bar.
  static const tintKey = Key('native_chrome.android.headerTint');

  @override
  Widget build(BuildContext context) {
    final viewport = Offset.zero & MediaQuery.sizeOf(context);
    final rect = Rect.fromLTRB(
      bar.left,
      0,
      bar.right,
      math.max(bar.bottom, bottom),
    ).intersect(viewport);
    if (!rect.isFinite || rect.isEmpty) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }
    final tinted = (rect.height - bar.bottom).clamp(0.0, rect.height);
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  key: tintKey,
                  width: double.infinity,
                  height: tint == null ? 0 : tinted,
                  child: ColoredBox(color: tint ?? Colors.transparent),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
