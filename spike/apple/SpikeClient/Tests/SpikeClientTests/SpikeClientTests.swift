import Connect
import SpikeClient
import XCTest

final class SpikeClientTests: XCTestCase {
  private var env: TestEnvironment!

  override func setUpWithError() throws {
    env = try TestEnvironment.load()
    executionTimeAllowance = 30
  }

  func testUnary() async throws {
    let connection = try env.connection(token: env.token)
    var request = Spike_V1_EchoRequest()
    request.message = "hi"
    let response = await connection.client.echo(request: request)
    XCTAssertNil(response.error)
    XCTAssertEqual(response.message?.message, "hi")
    // the server also accepts HTTP/1.1, so a silent downgrade would pass everything else
    XCTAssertTrue(connection.trust.protocols.contains("h2"), "protocols: \(connection.trust.protocols)")
  }

  func testBadToken() async throws {
    for token in [nil, "wrong"] {
      let client = try env.connection(token: token).client
      let response = await client.echo(request: Spike_V1_EchoRequest())
      XCTAssertEqual(response.code, .unauthenticated, "echo with token \(String(describing: token))")
      do {
        _ = try await take(1, from: client)
        XCTFail("watch with token \(String(describing: token)) succeeded")
      } catch let error as ConnectError {
        XCTAssertEqual(error.code, .unauthenticated, "watch with token \(String(describing: token))")
      }
    }
  }

  func testStream() async throws {
    let seqs = try await take(5, from: env.connection(token: env.token).client)
    XCTAssertEqual(seqs, consecutive(from: seqs[0], count: 5))
  }

  func testResume() async throws {
    let client = try env.connection(token: env.token).client
    let first = try await take(3, from: client)
    let last = try XCTUnwrap(first.last)
    // let the log move past last+3 so the resumed events can only come from replay
    try await Task.sleep(for: env.watchInterval * 5)
    let resumed = try await take(3, from: client, afterSeq: last)
    XCTAssertEqual(resumed, consecutive(from: last + 1, count: 3))
  }

  func testRotatedLeaf() async throws {
    let connection = try env.connection(token: env.token)
    let response = await connection.client.echo(request: Spike_V1_EchoRequest())
    XCTAssertNil(response.error)
    let leaf = try XCTUnwrap(connection.trust.leafFingerprints.last)
    XCTAssertNotEqual(leaf, env.initialLeafSHA256, "server is still serving the leaf it started with")
  }

  func testWrongCA() async throws {
    let connection = try env.connection(token: env.token, anchor: env.wrongCA)
    let response = await connection.client.echo(request: Spike_V1_EchoRequest())
    XCTAssertNil(response.message)
    XCTAssertEqual(connection.trust.trustRejections, 1)
  }
}
