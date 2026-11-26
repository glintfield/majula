import Connect
import Foundation
import SpikeClient
import XCTest

struct TestEnvironment {
  let url: URL
  let token: String
  let ca: Data
  let wrongCA: Data
  let initialLeafSHA256: String
  let watchInterval: Duration

  static func load() throws -> TestEnvironment {
    let env = ProcessInfo.processInfo.environment
    func value(_ key: String) throws -> String {
      guard let value = env[key], !value.isEmpty else {
        throw XCTSkip("\(key) unset: run spike/apple/scripts/test.sh")
      }
      return value
    }
    guard let url = URL(string: try value("SPIKE_URL")),
      let ca = Data(base64Encoded: try value("SPIKE_CA_DER_B64")),
      let wrongCA = Data(base64Encoded: try value("SPIKE_WRONG_CA_DER_B64")),
      let intervalMs = Int(try value("SPIKE_WATCH_INTERVAL_MS"))
    else {
      throw XCTSkip("malformed spike env")
    }
    return TestEnvironment(
      url: url, token: try value("SPIKE_TOKEN"), ca: ca, wrongCA: wrongCA,
      initialLeafSHA256: try value("SPIKE_INITIAL_LEAF_SHA256"),
      watchInterval: .milliseconds(intervalMs)
    )
  }

  func connection(token: String?, anchor: Data? = nil) throws -> SpikeConnection {
    try SpikeConnection(baseURL: url, token: token, anchorDER: anchor ?? ca)
  }
}

/// take opens a Watch stream and returns the first n seqs, throwing the stream's error if it ends first.
func take(_ n: Int, from client: Spike_V1_SpikeServiceClient, afterSeq: UInt64? = nil) async throws -> [UInt64] {
  let stream = client.watch()
  defer { stream.cancel() }
  var request = Spike_V1_WatchRequest()
  if let afterSeq { request.afterSeq = afterSeq }
  try stream.send(request)
  var seqs: [UInt64] = []
  for await result in stream.results() {
    switch result {
    case .headers:
      continue
    case .message(let event):
      seqs.append(event.seq)
      if seqs.count == n { return seqs }
    case .complete(let code, let error, _):
      throw error ?? ConnectError(code: code, message: "stream ended after \(seqs.count) events")
    }
  }
  return seqs
}

func consecutive(from first: UInt64, count: Int) -> [UInt64] {
  (0..<UInt64(count)).map { first + $0 }
}
