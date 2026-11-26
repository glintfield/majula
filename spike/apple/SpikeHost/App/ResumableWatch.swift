import Connect
import Foundation
import Observation
import SpikeClient

/// ResumableWatch keeps a Watch stream open, resuming from the last seq it saw after every drop.
@MainActor @Observable
final class ResumableWatch {
  private(set) var lastSeq: UInt64 = 0
  private(set) var connects = 0
  private(set) var gaps = 0
  private(set) var status = "idle"

  private let connection: SpikeConnection?
  private var task: Task<Void, Never>?

  private static let terminalCodes: Set<Code> = [.unauthenticated, .failedPrecondition, .outOfRange]

  init(connection: SpikeConnection?) {
    self.connection = connection
    if connection == nil { status = "misconfigured" }
  }

  static func fromEnvironment() -> ResumableWatch {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["SPIKE_URL"].flatMap(URL.init(string:)),
      let ca = env["SPIKE_CA_DER_B64"].flatMap({ Data(base64Encoded: $0) })
    else { return ResumableWatch(connection: nil) }
    return ResumableWatch(
      connection: try? SpikeConnection(baseURL: url, token: env["SPIKE_TOKEN"], anchorDER: ca)
    )
  }

  func start() {
    guard let connection, task == nil else { return }
    task = Task { await run(connection.client) }
  }

  func stop() {
    task?.cancel()
    task = nil
    if connection != nil { status = "stopped" }
  }

  private func run(_ client: Spike_V1_SpikeServiceClient) async {
    var backoff: Duration = .milliseconds(250)
    while !Task.isCancelled {
      connects += 1
      status = "streaming"
      let code = await consume(client, onFirstEvent: { backoff = .milliseconds(250) })
      if Task.isCancelled { return }
      if Self.terminalCodes.contains(code) {
        status = "terminal: \(code)"
        return
      }
      status = "reconnecting"
      try? await Task.sleep(for: backoff)
      backoff = min(backoff * 2, .seconds(5))
    }
  }

  private func consume(_ client: Spike_V1_SpikeServiceClient, onFirstEvent: () -> Void) async -> Code {
    let stream = client.watch()
    defer { stream.cancel() }
    var request = Spike_V1_WatchRequest()
    if lastSeq > 0 { request.afterSeq = lastSeq }
    do {
      try stream.send(request)
    } catch {
      return .unknown
    }
    var receivedAny = false
    for await result in stream.results() {
      if Task.isCancelled { return .canceled }
      switch result {
      case .headers:
        continue
      case .message(let event):
        if !receivedAny { onFirstEvent() }
        receivedAny = true
        // the first event of the first connect has no predecessor to compare against
        if lastSeq > 0, event.seq != lastSeq + 1 { gaps += 1 }
        lastSeq = event.seq
      case .complete(let code, _, _):
        return code
      }
    }
    return .unknown
  }
}
