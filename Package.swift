// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "swift-msi-enum-probe",
  targets: [
    // msi.h isn't part of Swift's WinSDK module, so expose it through a C shim.
    .target(
      name: "CMsi",
      linkerSettings: [.linkedLibrary("msi")]
    ),
    .executableTarget(
      name: "swift-msi-enum-probe",
      dependencies: ["CMsi"]
    ),
  ]
)
