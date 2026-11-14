package dev.nativechrome.native_chrome

import android.graphics.drawable.Drawable
import android.view.Menu
import com.google.android.material.bottomnavigation.BottomNavigationView

/** Owns the actual menu items on a host-configured bottom navigation view. */
class NativeChromeBottomMenu(
    private val view: BottomNavigationView,
    private val requestSelection: (Int) -> Boolean,
) : AutoCloseable {
    data class Item(val id: Int, val label: String, val icon: Drawable?)

    private var applying = false
    private var ids: List<Int> = emptyList()
    private var closed = false
    private val accessibilityDetails = mutableMapOf<Int, String>()

    init {
        view.setOnItemSelectedListener { applying || (!closed && requestSelection(it.itemId)) }
        view.setOnItemReselectedListener { if (!closed && !applying) requestSelection(it.itemId) }
    }

    fun setItems(items: List<Item>) {
        if (closed) return
        val next = items.map(Item::id)
        require(next.distinct().size == next.size)
        applying = true
        try {
            if (ids != next) {
                val selected = view.selectedItemId
                accessibilityDetails.keys.retainAll(next.toSet())
                view.menu.clear()
                items.forEachIndexed { position, item ->
                    val menuItem = view.menu.add(Menu.NONE, item.id, position, item.label)
                    menuItem.icon = item.icon
                    updateDescription(menuItem, item.id)
                }
                ids = next
                if (selected in ids) view.selectedItemId = selected
            } else {
                for (item in items) {
                    val previous = view.menu.findItem(item.id) ?: continue
                    if (previous.title != item.label) previous.title = item.label
                    if (previous.icon !== item.icon) previous.icon = item.icon
                    updateDescription(previous, item.id)
                }
            }
        } finally {
            applying = false
        }
    }

    fun update(id: Int, label: String?, enabled: Boolean, accessibility: String?) {
        if (closed) return
        val item = view.menu.findItem(id) ?: return
        if (label != null && item.title != label) item.title = label
        if (item.isEnabled != enabled) item.isEnabled = enabled
        if (accessibility == null) accessibilityDetails.remove(id) else accessibilityDetails[id] = accessibility
        updateDescription(item, id)
    }

    private fun updateDescription(item: android.view.MenuItem, id: Int) {
        val details = accessibilityDetails[id]
        val description = if (details == null) item.title else "${item.title}, $details"
        if (item.contentDescription != description) item.contentDescription = description
    }

    fun select(id: Int) {
        if (closed || id !in ids || view.selectedItemId == id) return
        applying = true
        try {
            view.selectedItemId = id
        } finally {
            applying = false
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        view.setOnItemSelectedListener(null)
        view.setOnItemReselectedListener(null)
    }
}
