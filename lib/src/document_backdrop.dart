import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'controller.dart';
import 'widgets.dart';

/// Paints behind a transparent shared iOS navigation bar in its route's
/// document stack or overlay. Place above the document and below any popup.
/// The document may scroll beneath this layer and still owns its rest inset.
///
/// This is a paint-only layer. Android, web, hidden bars and hosts without a
/// current measured bar do not paint. A missing Reduce Transparency report
/// also defers painting until the host provides it.
class NativeChromeDocumentBackdrop extends StatelessWidget {
  const NativeChromeDocumentBackdrop({
    super.key,
    this.visible = true,
    this.opacity = 1,
    this.reducedTransparencyColor,
  });

  final bool visible;
  final double opacity;

  /// Solid surface while iOS Reduce Transparency is enabled.
  /// Defaults to the current scaffold background.
  final Color? reducedTransparencyColor;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        !visible ||
        !opacity.isFinite ||
        opacity <= 0) {
      return const SizedBox.shrink();
    }
    final controller = NativeChrome.maybeOf(context);
    final geometry = controller?.geometry;
    final frame = geometry?.iosTopBarFrame;
    final reduced = geometry?.iosReduceTransparency;
    if (controller == null ||
        !controller.nativeAvailable ||
        controller.rendererFor(ChromeBarKind.top) != ChromeRenderer.native ||
        geometry == null ||
        !geometry.measured ||
        !geometry.topBarVisible ||
        frame == null ||
        !frame.isFinite ||
        frame.isEmpty ||
        reduced == null) {
      return const SizedBox.shrink();
    }

    final viewport = Offset.zero & MediaQuery.sizeOf(context);
    final rect = geometry
        .topBarRect(viewport.size)
        .intersect(viewport)
        .intersect(Rect.fromLTRB(frame.left, 0, frame.right, viewport.bottom));
    if (!rect.isFinite || rect.isEmpty) return const SizedBox.shrink();

    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: reduced
              ? ColoredBox(
                  color:
                      reducedTransparencyColor ??
                      Theme.of(context).scaffoldBackgroundColor,
                )
              : Opacity(
                  opacity: opacity.clamp(0, 1).toDouble(),
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      blendMode: BlendMode.src,
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
