import XCTest
@testable import flutter_nfc_kit_session

final class IOSPendingOperationControllerTests: XCTestCase {
    func testFinishCompletesPendingPollOnce() {
        let controller = IOSPendingOperationController<String>()
        XCTAssertNotNil(controller.begin("poll"))

        XCTAssertEqual(controller.takeCurrent(), "poll")
        XCTAssertNil(controller.takeCurrent())
    }

    func testFinishAfterTagDiscoveryIsHarmless() {
        let controller = IOSPendingOperationController<String>()
        let operationID = controller.begin("poll")!
        XCTAssertEqual(controller.take(operationID: operationID), "poll")

        XCTAssertNil(controller.takeCurrent())
    }

    func testRepeatedFinishIsHarmless() {
        let controller = IOSPendingOperationController<String>()
        XCTAssertNotNil(controller.begin("poll"))

        XCTAssertEqual(controller.takeCurrent(), "poll")
        XCTAssertNil(controller.takeCurrent())
    }

    func testDetachCompletesPendingPollOnce() {
        let controller = IOSPendingOperationController<String>()
        XCTAssertNotNil(controller.begin("poll"))

        XCTAssertEqual(controller.takeCurrent(), "poll")
        XCTAssertNil(controller.takeCurrent())
    }

    func testMatchingCallbackTakesPendingPollOnce() {
        let controller = IOSPendingOperationController<String>()
        let operationID = controller.begin("poll")!

        XCTAssertEqual(controller.take(operationID: operationID), "poll")
        XCTAssertNil(controller.take(operationID: operationID))
    }

    func testStaleCallbackCannotTakeNewPoll() {
        let controller = IOSPendingOperationController<String>()
        let oldOperationID = controller.begin("old")!
        XCTAssertEqual(controller.take(operationID: oldOperationID), "old")
        let newOperationID = controller.begin("new")!

        XCTAssertNil(controller.take(operationID: oldOperationID))
        XCTAssertEqual(controller.take(operationID: newOperationID), "new")
    }

    func testSecondPendingPollIsRejected() {
        let controller = IOSPendingOperationController<String>()

        XCTAssertNotNil(controller.begin("first"))
        XCTAssertNil(controller.begin("second"))
        XCTAssertEqual(controller.takeCurrent(), "first")
    }
}
