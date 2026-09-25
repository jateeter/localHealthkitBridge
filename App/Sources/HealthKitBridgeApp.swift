import SwiftUI
import UIKit
import UserNotifications

/// Registers the HealthKit observers at application launch, not from a view.
///
/// When iOS relaunches the app in the background to deliver HealthKit data,
/// no window and no view are created, so a SwiftUI `.task` never runs. The
/// observers used to be started only from ContentView's `.task`, so a
/// background relaunch woke an app with nothing registered and delivered
/// nothing (M5 device walk-through, 2026-09-24). HealthKit expects the queries
/// to be set up in `didFinishLaunching`.
final class BridgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            print("HealthKitBridge didFinishLaunching state=\(application.applicationState.rawValue)")
            await BridgeModel.shared.restoreHealthKitRuntimeState()
        }
        return true
    }
}

@main
struct HealthKitBridgeApp: App {
    @UIApplicationDelegateAdaptor(BridgeAppDelegate.self) private var appDelegate
    // The same instance the app delegate restores at launch: one bridge per process.
    @StateObject private var model = BridgeModel.shared

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
                    await model.restoreHealthKitRuntimeState()
                    // e2e hook: `simctl launch ... -autoTestPush 1` pushes one
                    // nominal batch on launch so simulator/device runs need no taps.
                    let autoTestPush = UserDefaults.standard.bool(forKey: "autoTestPush")
                        || launchArgumentBool(for: "autoTestPush")
                        || launchEnvironmentBool("AUTO_TEST_PUSH", "HEALTHKIT_AUTO_TEST_PUSH")
                    // Never log process arguments: device/e2e launches may use
                    // them for credentials. Only non-sensitive mode flags are
                    // safe to expose in diagnostics.
                    print("HealthKitBridge launch autoTestPush=\(autoTestPush)")
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
