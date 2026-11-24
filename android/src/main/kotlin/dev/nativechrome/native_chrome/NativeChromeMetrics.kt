package dev.nativechrome.native_chrome

import android.content.Context

/**
 * The configuration values that native chrome views bake into pixel sizes
 * when they are built: text scale (sp) and screen density (dp).
 *
 * An activity that handles `fontScale` or `density` changes itself
 * (`android:configChanges`) is not recreated, so views built earlier keep
 * their old sizes. Hosts compare a snapshot taken when they built their
 * views with [of] the current configuration, and rebuild when it differs.
 * Context snapshots (`createConfigurationContext`) must be recreated too.
 */
data class NativeChromeMetrics(val fontScale: Float, val densityDpi: Int) {
    companion object {
        fun of(context: Context): NativeChromeMetrics =
            context.resources.configuration.let { NativeChromeMetrics(it.fontScale, it.densityDpi) }
    }
}
