import SwiftUI

@main
struct HealthKitBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.refreshStatus()
                    // e2e hook: `simctl launch ... -autoTestPush 1` pushes one
                    // nominal batch on launch so simulator runs need no taps.
                    if UserDefaults.standard.bool(forKey: "autoTestPush") {
                        await model.sendTestBatch()
                    }
                }
        }
    }
}
