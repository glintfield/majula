import Connect
import CryptoKit
import Foundation
import os
import Security

/// TrustObserver records what the anchored trust evaluation and the transport saw.
public final class TrustObserver: Sendable {
  private struct State {
    var leafFingerprints: [String] = []
    var trustRejections = 0
    var protocols: [String] = []
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// SHA-256 hex of each leaf certificate the server presented, in handshake order.
  public var leafFingerprints: [String] { state.withLock { $0.leafFingerprints } }
  public var trustRejections: Int { state.withLock { $0.trustRejections } }
  /// ALPN protocol names (`h2`, `http/1.1`) of finished requests.
  public var protocols: [String] { state.withLock { $0.protocols } }

  func recordLeaf(_ fingerprint: String) { state.withLock { $0.leafFingerprints.append(fingerprint) } }
  func recordRejection() { state.withLock { $0.trustRejections += 1 } }
  func recordProtocol(_ name: String) { state.withLock { $0.protocols.append(name) } }
}

// URLSessionHTTPClient's private session delegate never forwards auth challenges, so it can't do custom trust
final class AnchoredHTTPClient: HTTPClientInterface {
  let observer = TrustObserver()
  private let session: URLSession
  private let delegate: SessionDelegate

  init(anchor: SecCertificate) {
    delegate = SessionDelegate(anchor: anchor, observer: observer)
    session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
  }

  deinit {
    session.finishTasksAndInvalidate()
  }

  func unary(
    request: HTTPRequest<Data?>,
    onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
    onResponse: @escaping @Sendable (HTTPResponse) -> Void
  ) -> Cancelable {
    let task = session.dataTask(with: URLRequest(request)) { data, response, error in
      if let response = response as? HTTPURLResponse {
        onResponse(HTTPResponse(
          code: Code.fromHTTPStatus(response.statusCode), headers: response.connectHeaders(),
          message: data, trailers: [:], error: error,
          tracingInfo: .init(httpStatus: response.statusCode)
        ))
      } else {
        let code = Code(urlError: error)
        onResponse(HTTPResponse(
          code: code, headers: [:], message: data, trailers: [:],
          error: ConnectError(code: code, message: error?.localizedDescription, exception: error),
          tracingInfo: nil
        ))
      }
    }
    delegate.track(task, Exchange(onMetrics: onMetrics, stream: nil))
    task.resume()
    return Cancelable { task.cancel() }
  }

  // Buffers the request body until sendClose, which covers server-streaming only, not bidi
  func stream(
    request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks
  ) -> RequestCallbacks<Data> {
    let pending = PendingStream()
    return RequestCallbacks(
      cancel: {
        switch pending.cancel() {
        case .started(let task): task.cancel()
        case .notStarted: responseCallbacks.receiveClose(.canceled, [:], nil)
        case .alreadyCanceled: break
        }
      },
      sendData: { pending.append($0) },
      sendClose: { [session, delegate] in
        var urlRequest = URLRequest(request)
        guard let body = pending.takeBody() else { return }
        urlRequest.httpBody = body
        let task = session.dataTask(with: urlRequest)
        guard pending.start(task) else { return }
        delegate.track(task, Exchange(
          onMetrics: responseCallbacks.receiveResponseMetrics, stream: responseCallbacks
        ))
        task.resume()
      }
    )
  }
}

private final class PendingStream: Sendable {
  private struct State {
    var body = Data()
    var task: URLSessionDataTask?
    var isCanceled = false
  }

  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  func append(_ data: Data) { state.withLockUnchecked { $0.body.append(data) } }

  func takeBody() -> Data? { state.withLockUnchecked { $0.isCanceled ? nil : $0.body } }

  func start(_ task: URLSessionDataTask) -> Bool {
    state.withLockUnchecked { state in
      guard !state.isCanceled else { return false }
      state.task = task
      return true
    }
  }

  enum CancelOutcome {
    case alreadyCanceled, notStarted
    case started(URLSessionDataTask)
  }

  func cancel() -> CancelOutcome {
    state.withLockUnchecked { state in
      guard !state.isCanceled else { return .alreadyCanceled }
      state.isCanceled = true
      return state.task.map { .started($0) } ?? .notStarted
    }
  }
}

private struct Exchange: @unchecked Sendable {
  let onMetrics: @Sendable (HTTPMetrics) -> Void
  let stream: ResponseCallbacks?
  var isClosed = false
}

private final class SessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
  private let anchor: SecCertificate
  private let observer: TrustObserver
  private let exchanges = OSAllocatedUnfairLock(uncheckedState: [Int: Exchange]())

  init(anchor: SecCertificate, observer: TrustObserver) {
    self.anchor = anchor
    self.observer = observer
  }

  func track(_ task: URLSessionTask, _ exchange: Exchange) {
    exchanges.withLockUnchecked { $0[task.taskIdentifier] = exchange }
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
      let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
      observer.recordLeaf(digest.map { String(format: "%02x", $0) }.joined())
    }
    if SecTrustEvaluateWithError(trust, nil) {
      completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
      observer.recordRejection()
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    defer { completionHandler(.allow) }
    guard let response = response as? HTTPURLResponse,
      let stream = exchanges.withLockUnchecked({ $0[dataTask.taskIdentifier]?.stream })
    else { return }
    stream.receiveResponseHeaders(response.connectHeaders())
    let code = Code.fromHTTPStatus(response.statusCode)
    if code != .ok {
      markClosed(dataTask)
      stream.receiveClose(code, [:], nil)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let stream = exchanges.withLockUnchecked { exchanges in
      exchanges[dataTask.taskIdentifier].flatMap { $0.isClosed ? nil : $0.stream }
    }
    stream?.receiveResponseData(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    for name in metrics.transactionMetrics.compactMap(\.networkProtocolName) {
      observer.recordProtocol(name)
    }
    exchanges.withLockUnchecked { $0[task.taskIdentifier] }?.onMetrics(HTTPMetrics(taskMetrics: metrics))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let exchange = exchanges.withLockUnchecked({ $0.removeValue(forKey: task.taskIdentifier) }),
      let stream = exchange.stream, !exchange.isClosed
    else { return }
    if let error {
      let code = Code(urlError: error)
      stream.receiveClose(code, [:], ConnectError(code: code, message: error.localizedDescription, exception: error))
    } else {
      stream.receiveClose(.ok, [:], nil)
    }
  }

  private func markClosed(_ task: URLSessionTask) {
    exchanges.withLockUnchecked { $0[task.taskIdentifier]?.isClosed = true }
  }
}

private extension URLRequest {
  init(_ request: HTTPRequest<Data?>) {
    self.init(url: request.url)
    httpMethod = request.method.rawValue
    httpBody = request.message
    for (name, values) in request.headers {
      setValue(values.joined(separator: ","), forHTTPHeaderField: name)
    }
  }
}

private extension HTTPURLResponse {
  func connectHeaders() -> Headers {
    allHeaderFields.reduce(into: Headers()) { headers, field in
      guard let name = (field.key as? String)?.lowercased() else { return }
      let value = field.value as? String ?? String(describing: field.value)
      headers[name, default: []].append(contentsOf: value.components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) })
    }
  }
}

private extension Code {
  init(urlError error: Error?) {
    switch (error as? URLError)?.code {
    case .cancelled?: self = .canceled
    case .timedOut?: self = .deadlineExceeded
    default: self = .unavailable
    }
  }
}
