package dev.nativechrome.native_chrome

import android.graphics.drawable.Drawable
import android.os.Build
import android.view.Menu
import android.view.MenuItem
import android.widget.ImageButton
import android.widget.Toolbar

/** Presents content in an existing framework Toolbar. The host owns its layout and styling. */
object NativeChromeToolbar {
    fun update(
        toolbar: Toolbar,
        title: String,
        subtitle: String?,
        foreground: Int,
        subtitleForeground: Int,
        upIcon: Drawable?,
        upLabel: String,
        upEnabled: Boolean,
        invokeUp: () -> Unit,
    ) {
        toolbar.title = title
        toolbar.subtitle = subtitle
        toolbar.setTitleTextColor(foreground)
        toolbar.setSubtitleTextColor(subtitleForeground)
        toolbar.navigationIcon = upIcon
        toolbar.navigationContentDescription = upLabel
        toolbar.setNavigationOnClickListener { if (upEnabled) invokeUp() }
        for (index in 0 until toolbar.childCount) {
            val child = toolbar.getChildAt(index)
            if (child is ImageButton && child.contentDescription == toolbar.navigationContentDescription) {
                child.isEnabled = upEnabled
            }
        }
    }

    fun updateMenu(
        menu: Menu,
        count: Int,
        itemId: (Int) -> Int,
        label: (Int) -> String,
        enabled: (Int) -> Boolean,
        configure: (Int, MenuItem) -> Unit,
    ) {
        menu.clear()
        repeat(count) { index ->
            val title = label(index)
            val item = menu.add(Menu.NONE, itemId(index), index, title)
            item.isEnabled = enabled(index)
            if (Build.VERSION.SDK_INT >= 26) item.contentDescription = title
            item.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            configure(index, item)
        }
    }
}
