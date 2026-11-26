package dev.majula.spike

import android.content.Intent
import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BackgroundingTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private lateinit var env: TestEnvironment
    private var activity: MainActivity? = null

    @Before
    fun setUp() {
        env = TestEnvironment.load()
    }

    @After
    fun tearDown() {
        activity?.let { instrumentation.runOnMainSync { it.finish() } }
    }

    @Test
    fun resumesAfterBackgrounding() {
        val watch = launch(keepStreamInBackground = false)
        val before = waitForLastSeq(watch, atLeast = 5)
        background(seconds = 5)
        // +40 lands inside the ~50 events emitted while away, so gaps == 0 below proves they were replayed
        waitForLastSeq(watch, atLeast = before + 40)

        val state = watch.state.value
        assertTrue("connects: ${state.connects}", state.connects >= 2)
        assertEquals(0, state.gaps)
        assertEquals("streaming", state.status)
    }

    // fails if Android cuts the stream, since nothing restarts it; 15 s outlasts the ~10 s cached-app freezer delay
    @Test
    fun observeUncancelledStreamInBackground() {
        val watch = launch(keepStreamInBackground = true)
        val before = waitForLastSeq(watch, atLeast = 5)
        val (atHome, beforeReturn) = background(seconds = 15) { watch.state.value }
        waitForLastSeq(watch, atLeast = before + 140)

        val after = watch.state.value
        Log.i(
            TAG,
            "uncancelled stream: received ${beforeReturn.received - atHome.received} events while stopped " +
                "(lastSeq ${atHome.lastSeq} -> ${beforeReturn.lastSeq}, status ${beforeReturn.status}); " +
                "after return connects=${after.connects} status=${after.status} gaps=${after.gaps}",
        )
        assertEquals("streaming", beforeReturn.status)
        assertEquals("streaming", after.status)
        // ~150 events are emitted in 15 s; a frozen or cut stream would deliver almost none of them while stopped
        assertTrue("received while stopped: ${beforeReturn.received - atHome.received}", beforeReturn.received - atHome.received >= 100)
        assertEquals(0, after.gaps)
    }

    private fun launch(keepStreamInBackground: Boolean): ResumableWatch {
        val context = instrumentation.targetContext
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra(MainActivity.EXTRA_URL, env.url)
                .putExtra(MainActivity.EXTRA_TOKEN, env.token)
                .putExtra(MainActivity.EXTRA_CA_DER_B64, env.caDerB64)
                .putExtra(MainActivity.EXTRA_KEEP_STREAM_IN_BACKGROUND, keepStreamInBackground),
        )
        val launched = instrumentation.waitForMonitorWithTimeout(monitor, 10_000) as MainActivity?
            ?: error("MainActivity did not launch")
        instrumentation.removeMonitor(monitor)
        activity = launched
        // the monitor fires before onCreate, so watch is only set once the activity has resumed
        waitForLifecycle(Lifecycle.State.RESUMED)
        var watch: ResumableWatch? = null
        instrumentation.runOnMainSync { watch = launched.watch }
        return watch ?: error("MainActivity launched without a watch")
    }

    // brought back with am start so the same instance resumes, like a launcher tap
    private fun <T> background(seconds: Long, sample: () -> T): Pair<T, T> {
        device.pressHome()
        waitForLifecycle(Lifecycle.State.CREATED)
        val atHome = sample()
        Thread.sleep(seconds * 1000)
        val beforeReturn = sample()
        device.executeShellCommand("am start -W --activity-reorder-to-front -n dev.majula.spike/.MainActivity")
        waitForLifecycle(Lifecycle.State.RESUMED)
        return atHome to beforeReturn
    }

    private fun background(seconds: Long) {
        background(seconds) {}
    }

    private fun waitForLifecycle(target: Lifecycle.State) {
        val deadline = System.currentTimeMillis() + 10_000
        var current: Lifecycle.State? = null
        while (System.currentTimeMillis() < deadline) {
            instrumentation.runOnMainSync { current = activity?.lifecycle?.currentState }
            if (current == target) return
            Thread.sleep(100)
        }
        fail("activity stayed $current, wanted $target")
    }

    private fun waitForLastSeq(watch: ResumableWatch, atLeast: Long): Long {
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            val seen = watch.state.value.lastSeq ?: 0
            if (seen >= atLeast) return seen
            Thread.sleep(200)
        }
        fail("lastSeq stayed at ${watch.state.value.lastSeq}, wanted $atLeast; state ${watch.state.value}")
        error("unreachable")
    }

    private companion object {
        const val TAG = "BackgroundingTest"
    }
}
