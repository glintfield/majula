package dev.majula.spike

import androidx.test.platform.app.InstrumentationRegistry
import java.security.cert.X509Certificate
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import spike.v1.Spike.WatchRequest
import spike.v1.SpikeServiceClient

/** TestEnvironment is what spike/android/scripts/test.sh passes as instrumentation arguments. */
class TestEnvironment private constructor(private val args: Map<String, String>) {
    val url = args.getValue("spikeUrl")
    val token = args.getValue("spikeToken")
    val caDerB64 = args.getValue("spikeCaDerB64")
    val ca: X509Certificate = SpikeConnection.certificate(caDerB64)
    val wrongCA: X509Certificate = SpikeConnection.certificate(args.getValue("spikeWrongCaDerB64"))
    val initialLeafSHA256 = args.getValue("spikeInitialLeafSha256")
    val watchInterval: Duration = args.getValue("spikeWatchIntervalMs").toLong().milliseconds

    fun connection(token: String?, anchor: X509Certificate = ca) = SpikeConnection(url, token, anchor)

    companion object {
        private val keys = listOf(
            "spikeUrl",
            "spikeToken",
            "spikeCaDerB64",
            "spikeWrongCaDerB64",
            "spikeInitialLeafSha256",
            "spikeWatchIntervalMs",
        )

        /** load skips the calling test unless the harness passed every argument. */
        fun load(): TestEnvironment {
            val bundle = InstrumentationRegistry.getArguments()
            for (key in keys) {
                assumeTrue("$key unset: run spike/android/scripts/test.sh", bundle.getString(key) != null)
            }
            return TestEnvironment(keys.associateWith { bundle.getString(it)!! })
        }
    }
}

/** take opens Watch, returns the seqs of the first [count] events, and closes the stream. */
suspend fun take(count: Int, client: SpikeServiceClient, afterSeq: Long? = null): List<Long> =
    withTimeout(15_000) {
        val stream = client.watch()
        try {
            val request = WatchRequest.newBuilder()
            afterSeq?.let { request.setAfterSeq(it) }
            stream.sendAndClose(request.build()).getOrThrow()
            val channel = stream.responseChannel()
            List(count) { channel.receive().seq }
        } finally {
            withContext(NonCancellable) { stream.receiveClose() }
        }
    }

fun consecutive(from: Long, count: Int): List<Long> = List(count) { from + it }
