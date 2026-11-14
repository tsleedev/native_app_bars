package dev.nativechrome.native_chrome

import android.app.ActionBar
import android.content.res.ColorStateList
import android.graphics.drawable.Drawable
import android.os.Build
import android.view.Menu
import android.view.MenuItem
import android.widget.Toolbar

/** Applies content to a framework ActionBar already installed on the host's Toolbar. */
object NativeChromeActionBar {
    data class Up(val label: String?, val enabled: Boolean, val invoke: () -> Unit)

    data class Action(
        val title: String,
        val description: String,
        val enabled: Boolean,
        val icon: Drawable? = null,
        val iconTint: ColorStateList? = null,
        val withText: Boolean = false,
        val invoke: (Menu, MenuItem) -> Unit,
    )

    fun update(actionBar: ActionBar?, toolbar: Toolbar, title: String, up: Up?) {
        actionBar?.title = title
        actionBar?.setDisplayHomeAsUpEnabled(up != null)
        actionBar?.setHomeButtonEnabled(up?.enabled == true)
        if (up == null) {
            toolbar.setNavigationOnClickListener(null)
        } else {
            actionBar?.setHomeAsUpIndicator(null as Drawable?)
            actionBar?.setHomeActionContentDescription(up.label)
            toolbar.setNavigationOnClickListener { if (up.enabled) up.invoke() }
        }
    }

    fun updateMenu(menu: Menu, actions: List<Action>) {
        menu.clear()
        actions.forEachIndexed { index, action ->
            val item = menu.add(0, index + 1, index, action.title)
            if (Build.VERSION.SDK_INT >= 26) item.contentDescription = action.description
            item.isEnabled = action.enabled
            if (action.icon != null) {
                item.icon = action.icon
                if (Build.VERSION.SDK_INT >= 26) item.iconTintList = action.iconTint
            }
            val placement = if (action.withText) MenuItem.SHOW_AS_ACTION_WITH_TEXT else 0
            item.setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM or placement)
            item.setOnMenuItemClickListener {
                if (action.enabled) action.invoke(menu, item)
                true
            }
        }
    }
}
