package dev.nativechrome.native_chrome

/**
 * Deferred UI work (posted to the view's queue) that belongs to one
 * generation of a rebuilt view state. [invalidate] cancels everything
 * scheduled before it, and a task that still runs (already dequeued) does
 * nothing unless its generation is current and [schedule]'s check passes.
 */
internal class GenerationalTasks(
    private val post: (Runnable) -> Unit,
    private val cancel: (Runnable) -> Unit,
) {
    var generation = 0
        private set
    private val pending = LinkedHashSet<Runnable>()

    val pendingCount: Int get() = pending.size

    fun schedule(isCurrent: () -> Boolean, action: () -> Unit): Runnable {
        val scheduled = generation
        lateinit var task: Runnable
        task = Runnable {
            pending.remove(task)
            if (scheduled == generation && isCurrent()) action()
        }
        pending.add(task)
        post(task)
        return task
    }

    fun invalidate() {
        generation += 1
        val stale = pending.toList()
        pending.clear()
        stale.forEach(cancel)
    }
}

/**
 * Menu item ids for one generation of a rebuilt toolbar menu. Every rebuild
 * uses new ids, so work queued for an earlier menu (by this package or by a
 * library that looks items up by id later) can never reach a reused id.
 */
internal class GenerationalMenuIds(private val stride: Int = 1000) {
    var base = 0
        private set

    fun next(): Int {
        base = if (base >= Int.MAX_VALUE / 2) stride else base + stride
        return base
    }

    fun id(index: Int): Int = base + index + 1

    /** Index of [itemId] in the current generation, or -1. */
    fun index(itemId: Int): Int {
        val index = itemId - base - 1
        return if (index in 0 until stride) index else -1
    }
}
