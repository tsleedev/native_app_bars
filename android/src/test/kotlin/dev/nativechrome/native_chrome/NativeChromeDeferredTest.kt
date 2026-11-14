package dev.nativechrome.native_chrome

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Top bar badges are attached by deferred UI work (after the toolbar lays
 * out its items). A menu rebuild or clear must cancel that work, and work
 * that still runs must not reach the next menu (3 -> 0 and
 * badge page -> other actions page within one UI queue turn).
 */
class NativeChromeDeferredTest {
    private val queue = ArrayList<Runnable>()
    private val cancelled = ArrayList<Runnable>()
    private val tasks = GenerationalTasks({ queue.add(it) }, { queue.remove(it); cancelled.add(it) })

    private fun drain() {
        while (queue.isNotEmpty()) queue.removeAt(0).run()
    }

    @Test
    fun runsWhenStillCurrent() {
        var attached = 0
        tasks.schedule({ true }) { attached++ }
        drain()
        assertEquals(1, attached)
        assertEquals(0, tasks.pendingCount)
    }

    @Test
    fun rebuildBeforeRunCancelsTheEarlierAttach() {
        // 3 unread, then 0 unread before the queued attach ran.
        var stale = 0
        tasks.schedule({ true }) { stale++ }
        tasks.invalidate() // menu rebuilt without a badge
        drain()
        assertEquals(0, stale)
        assertEquals(1, cancelled.size, "pending work is removed from the queue")
        assertEquals(0, tasks.pendingCount)
    }

    @Test
    fun staleTaskThatStillRunsDoesNothing() {
        // The runnable was already dequeued when the rebuild happened.
        var stale = 0
        val task = tasks.schedule({ true }) { stale++ }
        queue.clear()
        tasks.invalidate()
        task.run()
        assertEquals(0, stale)
    }

    @Test
    fun newGenerationWorkRunsAfterRebuild() {
        var old = 0
        var current = 0
        tasks.schedule({ true }) { old++ }
        tasks.invalidate() // badge page -> other actions page
        tasks.schedule({ true }) { current++ }
        drain()
        assertEquals(0, old)
        assertEquals(1, current)
    }

    @Test
    fun itemNoLongerCurrentSkipsTheAttach() {
        var attached = 0
        tasks.schedule({ false }) { attached++ }
        drain()
        assertEquals(0, attached)
    }

    @Test
    fun menuIdsAreNewForEveryGeneration() {
        val ids = GenerationalMenuIds()
        ids.next()
        val first = ids.id(0)
        assertEquals(0, ids.index(first))
        ids.next()
        val second = ids.id(0)
        assertNotEquals(first, second, "an id from an earlier menu is never reused")
        assertEquals(-1, ids.index(first), "an earlier id maps to no current action")
        assertEquals(2, ids.index(ids.id(2)))
    }

    @Test
    fun tabLabelsAreAlwaysShown() {
        // NavigationBarView.LABEL_VISIBILITY_LABELED; AUTO (-1) / SELECTED (0)
        // would hide unselected labels on a four-tab bar or rail.
        assertEquals(1, NativeChromeTabStyle.LABEL_VISIBILITY)
    }

    @Test
    fun railIsOptIn() {
        val tab = mapOf(
            "ownerToken" to 1, "routeSession" to 1, "semanticRevision" to 1,
            "selectedId" to "a", "items" to listOf(mapOf("id" to "a", "label" to "A", "icon" to mapOf("key" to "k"))),
        )
        assertFalse(NativeChromeTabSpec.parse(tab)!!.rail)
        assertTrue(NativeChromeTabSpec.parse(tab + ("rail" to true))!!.rail)
    }
}
