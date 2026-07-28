import SwiftUI
import UserNotifications

@main
struct HealthKitBridgeApp: App {
    @StateObject private var model = BridgeModel()

    init() {
        let reviewAction = UNNotificationAction(
            identifier: "OPEN_PATIENT_MONITOR",
            title: "Review",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "PATIENT_MONITOR_STATUS",
            actions: [reviewAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.refreshStatus()
                    // e2e hook: `simctl launch ... -autoTestPush 1` pushes one
                    // nominal batch on launch so simulator/device runs need no taps.
                    let autoTestPush = UserDefaults.standard.bool(forKey: "autoTestPush")
                        || launchArgumentBool(for: "autoTestPush")
                        || launchEnvironmentBool("AUTO_TEST_PUSH", "HEALTHKIT_AUTO_TEST_PUSH")
                    print("HealthKitBridge launch autoTestPush=\(autoTestPush) args=\(ProcessInfo.processInfo.arguments)")
                    if autoTestPush {
                        await model.sendTestBatch()
                    }
#if DEBUG
                    let seedHealthData = UserDefaults.standard.bool(forKey: "seedHealthData")
                        || launchArgumentBool(for: "seedHealthData")
                        || launchEnvironmentBool("SEED_HEALTH_DATA", "HEALTHKIT_SEED_HEALTH_DATA")
                    print("HealthKitBridge launch seedHealthData=\(seedHealthData)")
                    if seedHealthData {
                        await model.seedAndObserve()
                    }
#endif
                }
        }
    }
}
