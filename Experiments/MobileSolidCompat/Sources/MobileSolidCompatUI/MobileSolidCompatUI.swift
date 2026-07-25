import Foundation
import MobileSolidCompatModel

#if canImport(SolidAuthSwiftUI)
import SolidAuthSwiftUI
#endif

/// Thin marker target for the iOS-only SolidAuthSwiftUI integration. The real
/// sign-in controller wrapper will be added only after Phase 0 proves that the
/// upstream package resolves and builds against the selected Xcode/iOS toolchain.
public enum MobileSolidAuthUIProbe {
    public static let requiresIOSBrowserSignIn = true
    public static let expectedRedirectScheme = "opencommons-health"
}
