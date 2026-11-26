import Connect
import Foundation
import Security

/// SpikeConnection builds a Connect client that trusts only the given CA, on its own URLSession.
public struct SpikeConnection: Sendable {
  public enum Error: Swift.Error {
    case invalidAnchor
  }

  public let client: Spike_V1_SpikeServiceClient
  public let trust: TrustObserver

  public init(baseURL: URL, token: String?, anchorDER: Data) throws {
    guard let anchor = SecCertificateCreateWithData(nil, anchorDER as CFData) else {
      throw Error.invalidAnchor
    }
    let http = AnchoredHTTPClient(anchor: anchor)
    let interceptors = token.map { token in
      [InterceptorFactory { _ in BearerAuthInterceptor(token: token) }]
    } ?? []
    let config = ProtocolClientConfig(
      host: baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec(),
      interceptors: interceptors
    )
    client = Spike_V1_SpikeServiceClient(client: ProtocolClient(httpClient: http, config: config))
    trust = http.observer
  }
}
