package dev.majula.spike

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.connectrpc.Code
import com.connectrpc.ConnectException
import com.connectrpc.ResponseMessage
import com.connectrpc.exceptionOrNull
import com.connectrpc.getOrNull
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.Protocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import spike.v1.Spike.EchoRequest

@RunWith(AndroidJUnit4::class)
class SpikeClientTest {
    private lateinit var env: TestEnvironment

    @Before
    fun setUp() {
        env = TestEnvironment.load()
    }

    @Test
    fun unary() = runBlocking<Unit> {
        val connection = env.connection(env.token)
        val response = connection.client.echo(EchoRequest.newBuilder().setMessage("hi").build())
        assertNull(response.exceptionOrNull())
        assertEquals("hi", response.getOrNull()?.message)
        // the server also accepts HTTP/1.1, so a silent downgrade would pass everything else
        assertTrue("protocols: ${connection.trust.protocols}", Protocol.HTTP_2 in connection.trust.protocols)
    }

    @Test
    fun badToken() = runBlocking<Unit> {
        for (token in listOf(null, "wrong")) {
            val client = env.connection(token).client
            val response = client.echo(EchoRequest.getDefaultInstance())
            assertEquals("echo with token $token", Code.UNAUTHENTICATED, (response as? ResponseMessage.Failure)?.cause?.code)
            try {
                take(1, client)
                fail("watch with token $token succeeded")
            } catch (e: ConnectException) {
                assertEquals("watch with token $token", Code.UNAUTHENTICATED, e.code)
            }
        }
    }

    @Test
    fun stream() = runBlocking<Unit> {
        val seqs = take(5, env.connection(env.token).client)
        assertEquals(consecutive(seqs[0], 5), seqs)
    }

    @Test
    fun resume() = runBlocking<Unit> {
        val client = env.connection(env.token).client
        val last = take(3, client).last()
        // let the log move past last+3 so the resumed events can only come from replay
        delay(env.watchInterval * 5)
        assertEquals(consecutive(last + 1, 3), take(3, client, afterSeq = last))
    }

    @Test
    fun rotatedLeaf() = runBlocking<Unit> {
        val connection = env.connection(env.token)
        assertNull(connection.client.echo(EchoRequest.getDefaultInstance()).exceptionOrNull())
        assertNotEquals("server is still serving the leaf it started with", env.initialLeafSHA256, connection.trust.leafFingerprints.last())
    }

    @Test
    fun wrongCA() = runBlocking<Unit> {
        val connection = env.connection(env.token, anchor = env.wrongCA)
        val response = connection.client.echo(EchoRequest.getDefaultInstance())
        assertNull(response.getOrNull())
        assertEquals(1, connection.trust.trustRejections)
        Log.i(TAG, "wrong CA surfaced as ${(response as? ResponseMessage.Failure)?.cause?.code}: ${response.exceptionOrNull()}")
    }

    private companion object {
        const val TAG = "SpikeClientTest"
    }
}
