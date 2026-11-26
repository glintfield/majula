package dev.majula.spike

import android.os.Bundle
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch

/** MainActivity streams Watch while started and resumes from the last seq after coming back to the foreground. */
class MainActivity : ComponentActivity() {
    var watch: ResumableWatch? = null
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = TextView(this)
        setContentView(text)

        val url = intent.getStringExtra(EXTRA_URL)
        val ca = intent.getStringExtra(EXTRA_CA_DER_B64)
        if (url == null || ca == null) {
            text.text = "launch with $EXTRA_URL and $EXTRA_CA_DER_B64"
            return
        }
        val connection = SpikeConnection(url, intent.getStringExtra(EXTRA_TOKEN), SpikeConnection.certificate(ca))
        val watch = ResumableWatch(connection.client).also { this.watch = it }

        if (intent.getBooleanExtra(EXTRA_KEEP_STREAM_IN_BACKGROUND, false)) {
            lifecycleScope.launch { watch.run() }
        } else {
            lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { watch.run() } }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) { watch.state.collect { text.text = it.toString() } }
        }
    }

    companion object {
        const val EXTRA_URL = "spikeUrl"
        const val EXTRA_TOKEN = "spikeToken"
        const val EXTRA_CA_DER_B64 = "spikeCaDerB64"
        const val EXTRA_KEEP_STREAM_IN_BACKGROUND = "keepStreamInBackground"
    }
}
