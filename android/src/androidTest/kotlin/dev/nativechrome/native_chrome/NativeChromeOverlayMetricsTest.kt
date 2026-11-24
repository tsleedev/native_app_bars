package dev.nativechrome.native_chrome

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.util.DisplayMetrics
import android.view.View
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
import org.junit.Assert.assertTrue
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
        textLeading: Boolean = false,
        rail: Boolean = false,
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
        ) + (if (textLeading) mapOf("leading" to mapOf("id" to "done", "label" to "Done", "enabled" to true, "style" to "text")) else emptyMap()),
        "tab" to mapOf(
            "ownerToken" to 2, "routeSession" to 1, "semanticRevision" to 1,
            "selectedId" to selected, "hidden" to false, "rail" to rail,
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

    private fun field(overlay: NativeChromeOverlay, name: String): Any? =
        NativeChromeOverlay::class.java.getDeclaredField(name).apply { isAccessible = true }.get(overlay)

    /** The activity handled a display size change to [dpi] (smallest width follows). */
    @Suppress("DEPRECATION")
    private fun setDensity(activity: OverlayTestActivity, overlay: NativeChromeOverlay, dpi: Int) {
        val res = activity.resources
        val metrics = DisplayMetrics().apply { setTo(res.displayMetrics) }
        val config = Configuration(res.configuration)
        val widthDp = metrics.widthPixels * DisplayMetrics.DENSITY_DEFAULT / dpi
        val heightDp = metrics.heightPixels * DisplayMetrics.DENSITY_DEFAULT / dpi
        config.densityDpi = dpi
        config.screenWidthDp = widthDp
        config.screenHeightDp = heightDp
        config.smallestScreenWidthDp = minOf(widthDp, heightDp)
        metrics.densityDpi = dpi
        metrics.density = dpi / DisplayMetrics.DENSITY_DEFAULT.toFloat()
        metrics.scaledDensity = metrics.density * config.fontScale
        res.updateConfiguration(config, metrics)
        overlay.dispatchConfigurationChanged(config)
    }

    private fun launch(map: Map<String, Any>, block: (ActivityScenario<OverlayTestActivity>, NativeChromeOverlay) -> Unit) {
        ActivityScenario.launch(OverlayTestActivity::class.java).use { scenario ->
            lateinit var overlay: NativeChromeOverlay
            lateinit var originalConfig: Configuration
            val originalMetrics = DisplayMetrics()
            scenario.onActivity { activity ->
                originalConfig = Configuration(activity.resources.configuration)
                originalMetrics.setTo(activity.resources.displayMetrics)
                overlay = NativeChromeOverlay(activity, { _, _ -> }, { 0 }, { null })
                activity.setContentView(overlay)
                overlay.apply(state(map))
            }
            instrumentation.waitForIdleSync()
            try {
                block(scenario, overlay)
            } finally {
                @Suppress("DEPRECATION")
                scenario.onActivity {
                    it.resources.updateConfiguration(originalConfig, originalMetrics)
                    overlay.dispatchConfigurationChanged(originalConfig)
                }
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

    /** Dark opaque pixels (title and action text) in the outgoing snapshot. */
    private fun textPixels(image: ImageView): Int {
        val bitmap: Bitmap = (image.drawable as BitmapDrawable).bitmap
        var count = 0
        for (y in 0 until bitmap.height step 2) for (x in 0 until bitmap.width step 2) {
            val c = bitmap.getPixel(x, y)
            if (Color.alpha(c) > 200 && Color.red(c) + Color.green(c) + Color.blue(c) < 200) count++
        }
        return count
    }

    @Test
    fun aTransitionBegunRightAfterTheRebuildCapturesTheNewBars() = launch(wire()) { scenario, overlay ->
        var laidOut = 0
        scenario.onActivity { laidOut = textPixels(run { phase(overlay, "begin", 9, 0.0); snapshot(overlay)!! }); phase(overlay, "end", 9, 1.0) }
        assertTrue("reference snapshot has text: $laidOut", laidOut > 50)
        var rebuilt = -1
        var snapshotHeight = 0
        var toolbarHeight = 0
        scenario.onActivity { activity ->
            setFontScale(activity, overlay, 2f)
            // Queued behind the rebuild, ahead of the next frame's layout.
            overlay.post {
                phase(overlay, "begin", 10, 0.0)
                val image = snapshot(overlay)!!
                rebuilt = textPixels(image)
                snapshotHeight = (image.drawable as BitmapDrawable).bitmap.height
                toolbarHeight = overlay.toolbar.height
            }
        }
        instrumentation.waitForIdleSync()
        assertTrue("snapshot taken before the next frame shows the new bar: $rebuilt", rebuilt > 50)
        assertTrue("new toolbar laid out ($toolbarHeight) and captured ($snapshotHeight)", toolbarHeight > 0 && snapshotHeight >= toolbarHeight)
        scenario.onActivity { phase(overlay, "end", 10, 1.0) }
    }

    @Test
    fun aRebuildThatMovesTheTabsToTheRailMovesTheirDim() =
        launch(wire(suspended = true, dimMs = 0, rail = true)) { scenario, overlay ->
            scenario.onActivity {
                assertEquals(View.VISIBLE, (field(overlay, "bottomDim") as View).visibility)
                assertEquals(View.INVISIBLE, (field(overlay, "railDim") as View).visibility)
            }
            // Smallest width >= 600dp: the opted-in tabs move to the side rail.
            scenario.onActivity { setDensity(it, overlay, 280) }
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertEquals(View.VISIBLE, overlay.railContainer.visibility)
                val railDim = field(overlay, "railDim") as View
                assertEquals(View.VISIBLE, railDim.visibility)
                assertEquals(1f, railDim.alpha, 0.01f)
                assertEquals(View.INVISIBLE, (field(overlay, "bottomDim") as View).visibility)
            }
        }

    @Test
    fun aRebuildWithTheTopBarHiddenDropsTheOldBarsViewsAndInput() = launch(wire(textLeading = true)) { scenario, overlay ->
        lateinit var oldToolbar: android.view.ViewGroup
        scenario.onActivity {
            assertNotNull(field(overlay, "leadingView"))
            oldToolbar = overlay.toolbar
            overlay.apply(state(wire(presentation = "hidden", textLeading = true)))
            setFontScale(it, overlay, 2f)
        }
        instrumentation.waitForIdleSync()
        scenario.onActivity {
            assertTrue(overlay.toolbar !== oldToolbar)
            assertNull(field(overlay, "leadingView"))
            assertNull(field(overlay, "customTitle"))
            assertEquals(0, (oldToolbar as androidx.appcompat.widget.Toolbar).menu.size())
            // Shown again: the leading control is on the new bar.
            overlay.apply(state(wire(textLeading = true)))
            val leading = field(overlay, "leadingView") as View
            assertTrue(leading.parent === overlay.toolbar)
        }
    }
}
