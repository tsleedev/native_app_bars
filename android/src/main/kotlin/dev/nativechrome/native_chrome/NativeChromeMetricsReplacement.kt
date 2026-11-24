package dev.nativechrome.native_chrome

/**
 * When an overlay built with old [NativeChromeMetrics] may be replaced.
 *
 * Never during a bar transition: the outgoing snapshot, its alpha, the
 * transition id that later `update`/`end` calls must match, and the native
 * input filter belong to the overlay that began it. A change seen during a
 * transition waits until that transition ends (its `end`, a `clear`, or a
 * state applied with no transition running). A restarted transition
 * (`begin` after `begin`) keeps waiting.
 */
internal class NativeChromeMetricsReplacement {
    var pending = false
        private set

    /** The metrics changed. True: replace now. */
    fun metricsChanged(transitionActive: Boolean): Boolean {
        if (transitionActive) {
            pending = true
            return false
        }
        pending = false
        return true
    }

    /** A transition ended, the overlay was cleared, or a state was applied. True: replace now. */
    fun settled(transitionActive: Boolean): Boolean {
        if (!pending || transitionActive) return false
        pending = false
        return true
    }
}
