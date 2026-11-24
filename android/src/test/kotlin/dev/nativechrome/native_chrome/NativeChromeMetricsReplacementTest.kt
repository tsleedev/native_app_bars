package dev.nativechrome.native_chrome

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * A runtime font size or display size change replaces the plugin overlay,
 * but never while a bar transition runs (its snapshot, transition id and
 * input filter belong to the overlay that began it).
 */
class NativeChromeMetricsReplacementTest {
    /** Minimal model of the overlay's transition id and replacement calls. */
    private class Overlay {
        val replacement = NativeChromeMetricsReplacement()
        var transitionId: Int? = null
        var replaced = 0

        fun metricsChanged() { if (replacement.metricsChanged(transitionId != null)) replaced++ }
        fun begin(id: Int) { transitionId = id }
        /** Matches the overlay: an update or end for another id is ignored. */
        fun update(id: Int): Boolean = id == transitionId
        fun end(id: Int) {
            if (id != transitionId) return
            transitionId = null
            if (replacement.settled(false)) replaced++
        }
        fun apply() { if (replacement.settled(transitionId != null)) replaced++ }
        fun clear() { transitionId = null; if (replacement.settled(false)) replaced++ }
    }

    @Test
    fun replacesAtOnceWithoutATransition() {
        val overlay = Overlay()
        overlay.metricsChanged()
        assertTrue(overlay.replaced == 1)
        assertFalse(overlay.replacement.pending)
    }

    @Test
    fun beginMetricsUpdateEndKeepsTheTransitionThenReplaces() {
        val overlay = Overlay()
        overlay.begin(7)
        overlay.metricsChanged()
        assertTrue(overlay.replaced == 0)
        assertTrue(overlay.replacement.pending)
        // The same overlay still owns the transition: updates match its id.
        assertTrue(overlay.update(7))
        overlay.apply() // a state update during the transition
        assertTrue(overlay.replaced == 0)
        overlay.end(7)
        assertTrue(overlay.replaced == 1)
        assertFalse(overlay.replacement.pending)
        overlay.apply()
        assertTrue(overlay.replaced == 1)
    }

    @Test
    fun aRestartedTransitionKeepsWaiting() {
        val overlay = Overlay()
        overlay.begin(1)
        overlay.metricsChanged()
        overlay.begin(2) // begin after begin
        overlay.end(1) // stale end is ignored
        assertTrue(overlay.replaced == 0)
        overlay.end(2)
        assertTrue(overlay.replaced == 1)
    }

    @Test
    fun clearOrALaterStateReleasesAPendingReplacement() {
        val cleared = Overlay()
        cleared.begin(3)
        cleared.metricsChanged()
        cleared.clear()
        assertTrue(cleared.replaced == 1)

        // An end that never arrives: the next state applied without a
        // transition running replaces it.
        val applied = Overlay()
        applied.begin(4)
        applied.metricsChanged()
        applied.transitionId = null
        applied.apply()
        assertTrue(applied.replaced == 1)
    }
}
