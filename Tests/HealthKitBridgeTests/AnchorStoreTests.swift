import XCTest
@testable import HealthKitBridge

final class AnchorStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "healthkit-bridge-anchor-tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRoundTripPerType() {
        let store = AnchorStore(defaults: defaults)
        let blob = Data([1, 2, 3])
        store.save(blob, for: "HKQuantityTypeIdentifierStepCount")
        XCTAssertEqual(store.anchorData(for: "HKQuantityTypeIdentifierStepCount"), blob)
        XCTAssertNil(store.anchorData(for: "HKCategoryTypeIdentifierSleepAnalysis"))
    }

    func testSaveNilClears() {
        let store = AnchorStore(defaults: defaults)
        store.save(Data([9]), for: "t")
        store.save(nil, for: "t")
        XCTAssertNil(store.anchorData(for: "t"))
    }

    func testReset() {
        let store = AnchorStore(defaults: defaults)
        store.save(Data([1]), for: "a")
        store.save(Data([2]), for: "b")
        store.reset(typeIdentifiers: ["a", "b"])
        XCTAssertNil(store.anchorData(for: "a"))
        XCTAssertNil(store.anchorData(for: "b"))
    }
}
