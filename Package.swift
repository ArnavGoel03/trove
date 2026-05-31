// swift-tools-version: 6.0
//
// Trove — SwiftPM build target.
//
// Why this exists: `build-macapp` previously ran a whole-module
// `swiftc -O *.swift` on every change, which means even a one-character
// edit recompiled all 45 source files. Wall time was ~60s for arm64
// alone, ~2 min universal. SwiftPM's incremental build tracker only
// recompiles changed files + their dependents — subsequent rebuilds
// drop to 5-15s.
//
// Layout choice: we use `path: "."` + an `exclude` list rather than
// moving the 45 .swift files into the conventional `Sources/Trove/`
// directory. The whole codebase already references files at top level
// (e.g. `~/bin/test-trove` does `swiftc *.swift`), and moving them
// would touch every script + tool that knows the layout. The
// `path: "."` approach keeps everything where it is.
//
// `parse-as-library` via `unsafeFlags`: required because `main.swift`
// uses the `@main` attribute on a SwiftUI `App` struct. Without the
// flag SwiftPM treats main.swift as having top-level code, which
// conflicts with `@main` and errors. Same flag the manual `swiftc`
// invocation has always passed.

import PackageDescription

let package = Package(
    name: "Trove",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Trove",
            path: ".",
            exclude: [
                // Non-Swift artifacts that live alongside the sources.
                "VERSION",
                "icon.icns",
                "Trove-direct.entitlements",
                "Trove-store.entitlements",
                "CHANGELOG.md",
                "README.md",
                "PRIVACY.md",
                "SHIPPING.md",
                "APPSTORE-LISTING.md",
                "CLAUDE.md",
                // Subdirectories that aren't part of the app target.
                "tests",            // SwiftPM test target would go in a separate target if we want it
                "icon",             // icon-source.swift compiles to a one-off icon-gen tool, not the app
                "iconset",          // raw PNGs piped into iconutil
                "dist",             // notarized output artifacts
                ".build",           // SwiftPM build cache
                ".claude",          // Claude Code session data
            ],
            swiftSettings: [
                // Mirror what `build-macapp` historically passed so the
                // `@main` attribute on the SwiftUI App struct compiles.
                .unsafeFlags(["-parse-as-library"], .when(configuration: .release)),
                .unsafeFlags(["-parse-as-library"], .when(configuration: .debug)),
            ]
        ),
    ]
)
