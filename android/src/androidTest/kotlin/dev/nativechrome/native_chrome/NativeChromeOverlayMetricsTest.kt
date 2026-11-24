package dev.nativechrome.native_chrome

import android.content.res.Configuration
import android.os.SystemClock
import android.view.ContextThemeWrapper
import android.widget.ImageView
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.android.material.appbar.MaterialToolbar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A font size or display size change handled by the activity (configChanges)
 * keeps the overlay. Its bars must show the new sizes, while a running bar
 * transition and the popup dim continue unchanged, including a transition
 * restarted (end then begin) in the same main-thread turn.
 */
@RunWith(AndroidJUnit4::class)
class NativeChromeOverlayMetricsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun wire(
        presentation: String = "opaque",
        suspended: Boolean = false,
        dimMs: Long = 0,
        selected: String = "browse",
    ) = mapOf(
        "protocol" to 2,
        "lease" to "L1",
        "stateRevision" to 1,
        "suspended" to suspended,
        "rtl" to false,
        "appearance" to mapOf("brightness" to "light"),
        "dim" to mapOf("color" to 0x8A000000L, "durationMs" to dimMs),
        "top" to mapOf(
            "ownerToken" to 1, "routeSession" to 1, "semanticRevision" to 1,
            "title" to "Library", "presentation" to presentation,
            "actions" to listOf(mapOf("id" to "save", "label" to "Save", "enabled" to true)),
        ),
        "tab" to mapOf(
            "ownerToken" to 2, "routeSession" to 1, "semanticRevision" to 1,
            "selectedId" to selected, "hidden" to false,
            "items" to listOf(
                mapOf("id" to "library", "label" to "Library", "enabled" to true),
                mapOf("id" to "browse", "label" to "Browse", "enabled" to true),
            ),
        ),
    )

    private fun state(map: Map<String, Any>): NativeChromeStateSpec = NativeChromeStateSpec.parse(map)!!

    private fun titleSize(overlay: NativeChromeOverlay): Float = titleSize(overlay.toolbar)

    private fun titleSize(toolbar: android.view.ViewGroup): Float {
        for (i in 0 until toolbar.childCount) {
            val child = toolbar.getChildAt(i)
            if (child is TextView && child.text?.toString() == "Library") return child.textSize
        }
        throw AssertionError("no title view")
    }

    private fun snapshot(overlay: NativeChromeOverlay): ImageView? =
        (0 until overlay.childCount).map(overlay::getChildAt).filterIsInstance<ImageView>().firstOrNull()

    private fun phase(overlay: NativeChromeOverlay, phase: String, id: Int, progress: Double) =
        overlay.transition(mapOf("phase" to phase, "id" to id, "progress" to progress))

    /** The activity handled a font scale change: update its resources and tell the views. */
    @Suppress("DEPRECATION")
    private fun setFontScale(activity: OverlayTestActivity, overlay: NativeChromeOverlay, scale: Float) {
        val config = Configuration(activity.resources.configuration).apply { fontScale = scale }
        activity.resources.updateConfiguration(config, activity.resources.displayMetrics)
        overlay.dispatchConfigurationChanged(config)
    }

    private fun launch(map: Map<String, Any>, block: (ActivityScenario<OverlayTestActivity>, NativeChromeOverlay) -> Unit) {
        ActivityScenario.launch(OverlayTestActivity::class.java).use { scenario ->
            lateinit var overlay: NativeChromeOverlay
            scenario.onActivity { activity ->
                overlay = NativeChromeOverlay(activity, { _, _ -> }, { 0 }, { null })
                activity.setContentView(overlay)
                overlay.apply(state(map))
            }
            instrumentation.waitForIdleSync()
            try {
                block(scenario, overlay)
            } finally {
                scenario.onActivity { setFontScale(it, overlay, 1f) }
                instrumentation.waitForIdleSync()
            }
        }
    }

    @Test
    fun fontScaleChangeRebuildsBarsAndKeepsTheRunningTransition() = launch(wire()) { scenario, overlay ->
        var before = 0f
        scenario.onActivity { activity ->
            before = titleSize(overlay)
            phase(overlay, "begin", 1, 0.0)
            assertNotNull(snapshot(overlay))
            setFontScale(activity, overlay, 2f)
        }
        instrumentation.waitForIdleSync()
        scenario.onActivity { activity ->
            // The bar shows the text size a toolbar built now has (Android 14+
            // scales large fonts nonlinearly, so not simply twice as large).
            val fresh = MaterialToolbar(
                ContextThemeWrapper(activity, com.google.android.material.R.style.Theme_Material3_Light_NoActionBar),
            ).apply { title = "Library" }
            val expected = titleSize(fresh)
            assert(expected > before * 1.3f) { "font scale did not apply: $before -> $expected" }
            assertEquals(expected, titleSize(overlay), 1f)
            // The transition that began before the change continues.
            phase(overlay, "update", 1, 0.5)
            assertEquals(0.5f, snapshot(overlay)!!.alpha, 0.01f)
            // Restart in one turn (end, then begin), as Dart does.
            phase(overlay, "end", 1, 1.0)
            phase(overlay, "begin", 2, 0.0)
        }
        instrumentation.waitForIdleSync()
        scenario.onActivity {
            val restarted = snapshot(overlay)
            assertNotNull(restarted)
            phase(overlay, "update", 2, 0.25)
            assertEquals(0.75f, restarted!!.alpha, 0.01f)
            phase(overlay, "end", 2, 1.0)
            assertNull(snapshot(overlay))
            assertEquals("browse", overlay.debugSnapshot()["selectedTab"])
        }
    }

    @Test
    fun fontScaleChangeDuringThePopupDimKeepsItsTiming() =
        launch(wire(presentation = "transparent")) { scenario, overlay ->
            // A transparent bar dims by fading the toolbar to 1 - 0x8A/255.
            val dimmed = 1f - 0x8A / 255f
            // The popup opens now: a 6s fade starts at `start`.
            scenario.onActivity {
                overlay.apply(state(wire(presentation = "transparent", suspended = true, dimMs = 6000)))
            }
            val start = SystemClock.uptimeMillis()
            SystemClock.sleep(1500)
            scenario.onActivity { setFontScale(it, overlay, 2f) }
            instrumentation.waitForIdleSync()
            // Just after the original end: a fade restarted at the change
            // would still be well short of its target here.
            SystemClock.sleep(maxOf(0L, 6000L + 200L - (SystemClock.uptimeMillis() - start)))
            scenario.onActivity {
                // Finished on the original schedule, on the rebuilt toolbar.
                assertEquals(dimmed, overlay.toolbar.alpha, 0.01f)
            }
        }
}
