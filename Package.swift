// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TPClassroom",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TPClassroomTeacher", targets: ["TPClassroomTeacher"]),
        .executable(name: "TPClassroomStudent", targets: ["TPClassroomStudent"]),
        .executable(name: "TPCRelease", targets: ["TPCRelease"]),
    ],
    targets: [
        // Shared code: network protocol, encrypted connections, auto-updater.
        .target(name: "ClassroomKit"),
        // The app the teacher uses.
        .executableTarget(name: "TPClassroomTeacher", dependencies: ["ClassroomKit"]),
        // The menu-bar app that runs on every student iMac.
        .executableTarget(name: "TPClassroomStudent", dependencies: ["ClassroomKit"]),
        // Command-line tool that signs releases for the auto-updater.
        .executableTarget(name: "TPCRelease"),
    ]
)
