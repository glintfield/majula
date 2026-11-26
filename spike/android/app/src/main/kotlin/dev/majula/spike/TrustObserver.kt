package dev.majula.spike

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.security.MessageDigest
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import okhttp3.Call
import okhttp3.Connection
import okhttp3.EventListener
import okhttp3.Handshake
import okhttp3.Protocol

/** TrustObserver records the protocols, served leaves and trust rejections of an OkHttp client's connections. */
class TrustObserver : EventListener() {
    private val lock = Any()
    private val _protocols = mutableListOf<Protocol>()
    private val _leafFingerprints = mutableListOf<String>()
    private var _trustRejections = 0

    val protocols: List<Protocol> get() = synchronized(lock) { _protocols.toList() }

    /** SHA-256 of each served leaf's DER, lowercase hex, in handshake order. */
    val leafFingerprints: List<String> get() = synchronized(lock) { _leafFingerprints.toList() }

    val trustRejections: Int get() = synchronized(lock) { _trustRejections }

    override fun connectionAcquired(call: Call, connection: Connection) {
        synchronized(lock) { _protocols += connection.protocol() }
    }

    override fun secureConnectEnd(call: Call, handshake: Handshake?) {
        val leaf = handshake?.peerCertificates?.firstOrNull() ?: return
        val digest = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
        synchronized(lock) { _leafFingerprints += digest.joinToString("") { "%02x".format(it) } }
    }

    override fun connectFailed(
        call: Call,
        inetSocketAddress: InetSocketAddress,
        proxy: Proxy,
        protocol: Protocol?,
        ioe: IOException,
    ) {
        if (generateSequence<Throwable>(ioe) { it.cause }.any { it is SSLHandshakeException || it is SSLPeerUnverifiedException }) {
            synchronized(lock) { _trustRejections++ }
        }
    }
}
