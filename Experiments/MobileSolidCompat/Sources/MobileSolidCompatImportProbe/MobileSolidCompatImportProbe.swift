import Foundation
import MobileSolidCompatModel

#if canImport(SolidAuthSwiftTools)
import SolidAuthSwiftTools
#endif

#if canImport(SolidResourcesSwift)
import SolidResourcesSwift
#endif

/// Compile-time probe for the non-UI upstream Solid packages. This target has
/// no runtime behavior; if it compiles for an iOS destination, the next Phase 0
/// step is to wrap real token/resource operations behind
/// `MobileSolidResourceAccessing`.
public enum MobileSolidImportProbe {
    public static let importsSolidAuthSwiftTools = true
    public static let importsSolidResourcesSwift = true
    public static let modelProducts = SolidSwiftPackageInventory.requiredProducts
}
