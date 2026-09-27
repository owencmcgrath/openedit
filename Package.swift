// swift-tools-version: 5.9
import Foundation
import PackageDescription

// SPM stamps the Mach-O's LC_BUILD_VERSION SDK field with the deployment
// target. macOS only grants apps the current system window appearance
// (Liquid Glass traffic lights, left-aligned title) when that field names a
// recent SDK, so record the actual SDK version here.
let sdkVersion: String = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-version", "--sdk", "macosx"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            return version
        }
    } catch {}
    return "26.0"
}()

let package = Package(
    name: "OpenEdit",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "OpenEdit",
            path: "Sources/OpenEdit",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", "13.0",
                    "-Xlinker", sdkVersion
                ])
            ]
        )
    ]
)
