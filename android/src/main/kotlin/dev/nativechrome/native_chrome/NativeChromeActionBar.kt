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

    /** Opt-in split title for [update]: see `NativeTopBar.titleAccessory`. */
    data class SplitTitle(
        val titleAction: NativeChromeSplitTitle.Control?,
        val accessory: NativeChromeSplitTitle.Control,
        val accessoryIcon: Drawable?,
        val foreground: Int? = null,
        /** Optional leading image control (for example an avatar) before the title. */
        val leading: NativeChromeSplitTitle.Control? = null,
        val leadingIcon: Drawable? = null,
    )

    private const val SPLIT_TITLE_TAG = "native_chrome.splitTitle"

    /**
     * [split] null (the default) keeps the platform title. A split title
     * replaces it with a one-line, end-truncated title and a separate
     * accessory button, each with at least a 48dp hit area.
     */
    fun update(actionBar: ActionBar?, toolbar: Toolbar, title: String, up: Up?, split: SplitTitle? = null) {
        if (split != null && actionBar != null) {
            val row = NativeChromeSplitTitle.build(
                context = actionBar.themedContext,
                title = title,
                textSize = 20f,
                foreground = split.foreground,
                titleAction = split.titleAction,
                accessory = split.accessory,
                accessoryIcon = split.accessoryIcon,
                leading = split.leading,
                leadingIcon = split.leadingIcon,
            ).apply { tag = SPLIT_TITLE_TAG }
            actionBar.setCustomView(row, ActionBar.LayoutParams(
                ActionBar.LayoutParams.WRAP_CONTENT,
                ActionBar.LayoutParams.WRAP_CONTENT,
                android.view.Gravity.START or android.view.Gravity.CENTER_VERTICAL,
            ))
            actionBar.setDisplayShowCustomEnabled(true)
            actionBar.setDisplayShowTitleEnabled(false)
        } else if (actionBar?.customView?.tag == SPLIT_TITLE_TAG) {
            // Only undo what a split title installed; other apps are untouched.
            actionBar.customView = null
            actionBar.setDisplayShowCustomEnabled(false)
            actionBar.setDisplayShowTitleEnabled(true)
        }
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
