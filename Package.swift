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
    dependencies: [
        // TOML parsing for the language registry (ARCHITECTURE.md 5.2). Foundation
        // has no TOML reader; this is the only third-party dependency the config
        // loader adds, and it is confined to the OpenEditConfig module.
        // 0.x releases may break API between minors, so pin exactly; bump
        // deliberately rather than letting a fresh resolve pick up 0.7.0.
        .package(url: "https://github.com/LebJe/TOMLKit.git", .exact("0.6.0")),

        // Tree-sitter syntax highlighting (ARCHITECTURE.md 5.4, 5.8). SwiftTreeSitter
        // is the binding the architecture doc names; the C runtime arrives
        // transitively through it. AGENTS/GRAMMARS.md records the source, license,
        // and pinned version of each grammar and how its query bundle reaches
        // OpenEdit.app.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),

        // Grammar parsers, one per bundled language. Each is pinned with `exact:`
        // to the newest release whose Package.swift statically lists the external
        // scanner: newer tags detect it with `FileManager.default.fileExists`,
        // which returns false when the manifest is evaluated as a dependency,
        // silently dropping the scanner and failing to link. See GRAMMARS.md.
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0")
    ],
    targets: [
        // Config loader (ARCHITECTURE.md 5.2). Split out from the app so its
        // behavior is testable and so #5/#7 can depend on the registry without
        // importing the AppKit shell.
        .target(
            name: "OpenEditConfig",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            path: "Sources/OpenEditConfig"
        ),
        // Tree-sitter highlighting (ARCHITECTURE.md 5.4, 5.8). Split out from the
        // AppKit shell so tokenization and the capture → dynamic-color mapping are
        // testable without a window. It takes a grammar *name* from the config
        // registry and knows nothing about the config loader itself.
        .target(
            name: "OpenEditHighlighting",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml")
            ],
            path: "Sources/OpenEditHighlighting"
        ),
        // Language-server availability (ARCHITECTURE.md 5.6). Split out from
        // the AppKit shell for the same reason as the config and highlighting
        // modules: PATH/literal-path resolution is testable with a controlled
        // PATH, no window needed. #6's process pool and #51's Settings
        // inventory consume the same `LanguageServerAvailability` result.
        .target(
            name: "OpenEditLSP",
            dependencies: ["OpenEditConfig", "OpenEditLog"],
            path: "Sources/OpenEditLSP"
        ),
        // Open-placement routing (ARCHITECTURE.md 5.1). Split out from the
        // AppKit shell for the same reason as the other modules: the custom
        // `openedit://` URL parsing and the reuse-vs-new-window decision are
        // Foundation-only and testable without a window server.
        .target(
            name: "OpenEditWindowing",
            path: "Sources/OpenEditWindowing"
        ),
        // Small logging seam for the CLI's `--log-level`/`--log-file`/`--debug`
        // flags (ARCHITECTURE.md 5.1). OSLog always; an optional append-only
        // file sink when the user asks for one.
        .target(
            name: "OpenEditLog",
            path: "Sources/OpenEditLog"
        ),
        .executableTarget(
            name: "OpenEdit",
            dependencies: ["OpenEditConfig", "OpenEditHighlighting", "OpenEditLSP", "OpenEditWindowing", "OpenEditLog"],
            path: "Sources/OpenEdit",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", "13.0",
                    "-Xlinker", sdkVersion
                ])
            ]
        ),
        // Controlled language server for #6's tests (not shipped with the
        // app). Behavior is driven by a JSON config path in the
        // OPENEDIT_TEST_LSP_CONFIG environment variable; see its main.swift.
        .executableTarget(
            name: "lsp-test-server",
            path: "Sources/LSPTestServer"
        ),
        .testTarget(
            name: "OpenEditConfigTests",
            dependencies: ["OpenEditConfig"],
            path: "Tests/OpenEditConfigTests",
            // Fixtures are read from the source tree via #filePath, not bundled.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "OpenEditHighlightingTests",
            dependencies: ["OpenEditHighlighting"],
            path: "Tests/OpenEditHighlightingTests"
        ),
        .testTarget(
            name: "OpenEditLSPTests",
            dependencies: ["OpenEditLSP", "OpenEditConfig"],
            path: "Tests/OpenEditLSPTests"
        ),
        // `OpenEditWindowingTests` also covers the app shell's window
        // components (the #37 gutter regression tests import the `OpenEdit`
        // executable module with `@testable`), so the app target is a
        // dependency of this test target.
        .testTarget(
            name: "OpenEditWindowingTests",
            dependencies: ["OpenEditWindowing", "OpenEdit"],
            path: "Tests/OpenEditWindowingTests"
        ),
        .testTarget(
            name: "OpenEditLogTests",
            dependencies: ["OpenEditLog"],
            path: "Tests/OpenEditLogTests"
        )
    ]
)
