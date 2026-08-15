// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Resolve Testing framework path from the active toolchain — XCTest.framework only
// ships with full Xcode.app, but Testing.framework ships with the CLT toolchain too.
let testingFrameworkPath: String = {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    task.arguments = ["-p"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    if task.terminationStatus == 0,
       let devDir = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !devDir.isEmpty {
        let xcodeFrameworks = devDir + "/Platforms/MacOSX.platform/Developer/Library/Frameworks"
        if FileManager.default.fileExists(atPath: xcodeFrameworks) { return xcodeFrameworks }
        let cltFrameworks = devDir + "/Library/Developer/Frameworks"
        if FileManager.default.fileExists(atPath: cltFrameworks) { return cltFrameworks }
    }
    return "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
}()

let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "eqYourMacbook",
    platforms: [.macOS("14.4")],
    targets: [
        .target(
            name: "eqYourMacbook",
            path: "Sources",
            // @main entry point; excluded so the test runner doesn't double-define it.
            exclude: ["App/eqYourMacbookApp.swift"],
            swiftSettings: commonSwiftSettings + [
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
        // Calls Testing.__swiftPMEntryPoint() directly, bypassing `swift test`'s
        // XCTest-bundle runner (which needs Xcode.app, not just CLT).
        .executableTarget(
            name: "eqYourMacbookTestRunner",
            dependencies: ["eqYourMacbook"],
            path: ".",
            exclude: [
                "CLAUDE.md",
                "PLAN.md",
                "README.md",
                "Resources",
                "Sources",
                "docs",
                "scripts",
                "eqYourMacbook.xcodeproj",
            ],
            sources: ["Tests/eqYourMacbookTests", "TestRunner"],
            swiftSettings: commonSwiftSettings + [
                .unsafeFlags([
                    "-F", testingFrameworkPath,
                    "-Xfrontend", "-disable-cross-import-overlays",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", testingFrameworkPath,
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", testingFrameworkPath,
                ]),
            ]
        ),
    ]
)
