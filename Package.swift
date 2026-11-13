// swift-tools-version: 6.0
import PackageDescription

// HomeFinance: native macOS-gezinsbegroting.
// Elke module is een eigen target, zodat je er één los kunt bouwen en testen:
//   swift test --filter HFImportTests
let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

let package = Package(
    name: "HomeFinance",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "HomeFinance", targets: ["HomeFinance"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "HFCore", dependencies: [grdb]),
        .target(name: "HFImport", dependencies: ["HFCore", grdb]),
        .target(name: "HFBudget", dependencies: ["HFCore", grdb]),
        .target(name: "HFRules", dependencies: ["HFCore", grdb]),
        .target(name: "HFInsight", dependencies: ["HFCore", grdb]),
        .target(name: "HFBackup", dependencies: ["HFCore", grdb]),
        .executableTarget(
            name: "HomeFinance",
            dependencies: ["HFCore", "HFImport", "HFBudget", "HFRules", "HFInsight", "HFBackup", grdb]
        ),
        .testTarget(name: "HFCoreTests", dependencies: ["HFCore", grdb]),
        .testTarget(name: "HFImportTests", dependencies: ["HFImport", "HFCore", grdb]),
        .testTarget(name: "HFBudgetTests", dependencies: ["HFBudget", "HFCore", grdb]),
        .testTarget(name: "HFRulesTests", dependencies: ["HFRules", "HFCore", grdb]),
        .testTarget(name: "HFInsightTests", dependencies: ["HFInsight", "HFCore", grdb]),
        .testTarget(name: "HFBackupTests", dependencies: ["HFBackup", "HFCore", grdb]),
        .testTarget(name: "IntegrationTests",
                    dependencies: ["HFCore", "HFImport", "HFBudget", "HFRules", "HFInsight", "HFBackup", grdb]),
    ],
    swiftLanguageModes: [.v5]
)
