package dev.nativechrome.native_chrome

import android.view.View
import com.google.android.material.tabs.TabLayout

/** Renders segments in a host-configured Material TabLayout. */
class NativeChromeTabLayout(private val control: TabLayout) : AutoCloseable {
    private var listener: TabLayout.OnTabSelectedListener? = null

    fun update(
        labels: List<String>,
        selectedIndex: Int,
        enabled: Boolean,
        configure: (View) -> Unit = {},
        selected: (Int) -> Unit,
    ) {
        close()
        if (control.tabCount != labels.size) {
            control.removeAllTabs()
            labels.forEach { control.addTab(control.newTab().setText(it), false) }
        } else labels.forEachIndexed { index, label -> control.getTabAt(index)?.text = label }
        control.selectTab(control.getTabAt(selectedIndex))
        for (index in labels.indices) {
            control.getTabAt(index)?.view?.let { tab ->
                tab.isEnabled = enabled
                configure(tab)
            }
        }
        listener = object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {
                if (enabled && control.isShown && tab.position in labels.indices) selected(tab.position)
            }
            override fun onTabUnselected(tab: TabLayout.Tab) = Unit
            override fun onTabReselected(tab: TabLayout.Tab) = Unit
        }.also(control::addOnTabSelectedListener)
    }

    override fun close() {
        listener?.let(control::removeOnTabSelectedListener)
        listener = null
    }
}
