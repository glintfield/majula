package dev.majula.spike

import com.connectrpc.ProtocolClientConfig
import com.connectrpc.extensions.GoogleJavaLiteProtobufStrategy
import com.connectrpc.impl.ProtocolClient
import com.connectrpc.okhttp.ConnectOkHttpClient
import com.connectrpc.simpleTimeouts
import java.io.ByteArrayInputStream
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64
import kotlin.time.Duration.Companion.seconds
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import spike.v1.SpikeServiceClient

/** SpikeConnection is a SpikeService client that trusts only [ca] and sends [token] as a bearer token. */
class SpikeConnection(url: String, token: String?, ca: X509Certificate) {
    val trust = TrustObserver()
    val client: SpikeServiceClient

    init {
        // no addPlatformTrustedCertificates(): the CA is the only anchor
        val certificates = HandshakeCertificates.Builder().addTrustedCertificate(ca).build()
        val builder = OkHttpClient.Builder()
            .sslSocketFactory(certificates.sslSocketFactory(), certificates.trustManager)
            // keeps one connect attempt per call, so a trust rejection is counted once
            .retryOnConnectionFailure(false)
            .eventListener(trust)
        if (token != null) {
            builder.addInterceptor { chain ->
                chain.proceed(chain.request().newBuilder().header("Authorization", "Bearer $token").build())
            }
        }
        val http = ConnectOkHttpClient(ConnectOkHttpClient.configureClient(builder).build())
        val config = ProtocolClientConfig(
            host = url,
            serializationStrategy = GoogleJavaLiteProtobufStrategy(),
            // the default oracle also caps streams at 10 s, which would end Watch
            timeoutOracle = simpleTimeouts(unaryTimeout = 10.seconds, streamTimeout = null),
        )
        client = SpikeServiceClient(ProtocolClient(http, config))
    }

    companion object {
        /** certificate parses a base64-encoded DER certificate. */
        fun certificate(derBase64: String): X509Certificate {
            val der = Base64.getDecoder().decode(derBase64)
            return CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(der)) as X509Certificate
        }
    }
}
