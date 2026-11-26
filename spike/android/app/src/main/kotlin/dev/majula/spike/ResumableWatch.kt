package dev.majula.spike

import com.connectrpc.ConnectException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import spike.v1.Spike.WatchRequest
import spike.v1.SpikeServiceClient

/** ResumableWatch streams Watch, resuming after the last seq it saw each time [run] is called again. */
class ResumableWatch(private val client: SpikeServiceClient) {
    data class State(
        val lastSeq: Long? = null,
        val received: Int = 0,
        val connects: Int = 0,
        /** Events whose seq wasn't lastSeq + 1: skips and duplicates both count. */
        val gaps: Int = 0,
        val status: String = "idle",
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    /** run streams until the server ends the stream, it fails, or the caller cancels. */
    suspend fun run() {
        _state.update { it.copy(connects = it.connects + 1, status = "connecting") }
        val stream = client.watch()
        try {
            val request = WatchRequest.newBuilder()
            _state.value.lastSeq?.let { request.setAfterSeq(it) }
            stream.sendAndClose(request.build()).getOrThrow()
            for (event in stream.responseChannel()) {
                _state.update {
                    val gap = it.lastSeq != null && event.seq != it.lastSeq + 1
                    it.copy(
                        lastSeq = event.seq,
                        received = it.received + 1,
                        gaps = it.gaps + if (gap) 1 else 0,
                        status = "streaming",
                    )
                }
            }
            _state.update { it.copy(status = "ended") }
        } catch (e: CancellationException) {
            _state.update { it.copy(status = "stopped") }
            throw e
        } catch (e: ConnectException) {
            _state.update { it.copy(status = "error: ${e.code}") }
        } finally {
            withContext(NonCancellable) { stream.receiveClose() }
        }
    }
}
