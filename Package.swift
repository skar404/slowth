// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Compile the actual app files; no copied sources or links to another checkout.
let runtimeSources: [String] = [
    "Shared/AppGroup.swift",
    "Shared/AppReviewCoordinator.swift",
    "RealtimeShield/CascadeClassifier.swift",
    "RealtimeShield/CascadePolicy.swift",
    "Debug/Shared/DebugModelSettings.swift",
    "Shared/FeatureFlags.swift",
    "RealtimeShield/FlatClassifier.swift",
    "RealtimeShield/ModelImageResizer.swift",
    "Shared/ModelSettings.swift",
    "Debug/Shared/SessionCapture.swift",
    "Debug/Shared/SessionCaptureArchive.swift",
    "Debug/Shared/SessionCaptureDeletion.swift",
    "Debug/Shared/SessionCaptureSettings.swift",
    "Debug/Broadcast/SessionJPEG.swift",
    "Debug/Shared/SessionUploadIdentity.swift",
    "Debug/Shared/SessionUploadIndex.swift",
    "Debug/Shared/SessionUploader.swift",
    "Debug/Transfer/DebugTransferProfile.swift",
    "Debug/Transfer/DebugS3Signer.swift",
    "Debug/Transfer/DebugTransferSnapshot.swift",
    "Debug/Transfer/DebugTransferTransport.swift",
    "RealtimeShield/SurfaceClassifier.swift",
    "RealtimeShield/SurfaceClassifierContracts.swift",
    "RealtimeShield/SurfaceClassifierFactory.swift",
    "RealtimeShield/SurfaceModelMetadata.swift",
    "RealtimeShield/SurfaceObservationState.swift",
]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func excludedPaths(in relative: String = "") -> [String] {
    let directory = root.appendingPathComponent(relative)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.sorted().filter { !$0.hasPrefix(".") }.flatMap { name -> [String] in
        let path = relative.isEmpty ? name : relative + "/" + name
        if runtimeSources.contains(path) { return [] }
        if runtimeSources.contains(where: { $0.hasPrefix(path + "/") }) {
            return excludedPaths(in: path)
        }
        return [path]
    }
}

let package = Package(
    name: "SlowthRuntimeTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CascadeRuntime", path: ".", exclude: excludedPaths(), sources: runtimeSources),
        .testTarget(name: "CascadeRuntimeTests", dependencies: ["CascadeRuntime"],
                    path: "tests/Runtime/Tests/CascadeRuntimeTests", sources: ["DebugTransferTests.swift"]),
    ]
)
