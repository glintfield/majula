import XCTest

final class BackgroundingUITests: XCTestCase {
  @MainActor
  func testResumesAfterBackgrounding() throws {
    let env = ProcessInfo.processInfo.environment
    let app = XCUIApplication()
    for key in ["SPIKE_URL", "SPIKE_TOKEN", "SPIKE_CA_DER_B64"] {
      guard let value = env[key] else { throw XCTSkip("\(key) unset: run spike/apple/scripts/test.sh") }
      app.launchEnvironment[key] = value
    }
    app.launch()

    let before = try waitForLastSeq(app, atLeast: 5, timeout: 15)
    XCUIDevice.shared.press(.home)
    sleep(5)
    app.activate()
    // +40 lands inside the ~50 events emitted while away, so gaps == 0 below proves they were replayed
    _ = try waitForLastSeq(app, atLeast: before + 40, timeout: 15)

    XCTAssertGreaterThanOrEqual(Int(value(app, "connects")) ?? 0, 2)
    XCTAssertEqual(value(app, "gaps"), "0")
    XCTAssertEqual(value(app, "status"), "streaming")
  }

  @MainActor
  private func waitForLastSeq(_ app: XCUIApplication, atLeast target: UInt64, timeout: TimeInterval) throws -> UInt64 {
    let deadline = Date().addingTimeInterval(timeout)
    var seen: UInt64 = 0
    while Date() < deadline {
      seen = UInt64(value(app, "lastSeq")) ?? 0
      if seen >= target { return seen }
      Thread.sleep(forTimeInterval: 0.2)
    }
    XCTFail("lastSeq stayed at \(seen), wanted \(target); status \(value(app, "status"))")
    return seen
  }

  // the subscript also matches the row's name text by label, so match the identifier alone
  @MainActor
  private func value(_ app: XCUIApplication, _ identifier: String) -> String {
    let element = app.staticTexts.matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    return element.exists ? element.label : ""
  }
}
