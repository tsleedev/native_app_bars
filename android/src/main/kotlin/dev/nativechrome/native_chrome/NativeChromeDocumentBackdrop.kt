package dev.nativechrome.native_chrome

import android.os.Build
import androidx.core.graphics.ColorUtils

/**
 * Android counterpart of a translucent top bar over a scrolling document:
 * the host bar paints [barTint] while Flutter blurs the document beneath it
 * (Dart `NativeChromeAndroidHeaderBackdrop`, which repeats the same tint
 * below the bar for a fixed page header).
 */
object NativeChromeDocumentBackdrop {
    /** Alpha of the bar surface over the blur. */
    const val BAR_ALPHA = 176

    /**
     * API 26 keeps an opaque bar: hosts there report no support and keep the
     * header above the document.
     */
    val supported: Boolean get() = Build.VERSION.SDK_INT > Build.VERSION_CODES.O

    /** The host bar's translucent surface, reported to Flutter as an ARGB Int. */
    fun barTint(surface: Int): Int = ColorUtils.setAlphaComponent(surface, BAR_ALPHA)
}
