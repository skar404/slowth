#if DEBUG
#if os(iOS)
import Combine
import Foundation
import Photos

final class DebugCapturePhotoLibrary: ObservableObject {
    @Published private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(
        for: .readWrite
    )
    @Published private(set) var pendingEvents = 0
    @Published private(set) var pendingBytes: Int64 = 0
    @Published private(set) var savedEvents = AppGroup.defaults.integer(
        forKey: DebugCaptureSettings.savedEventCountStorageKey
    )
    @Published private(set) var isImporting = false
    @Published private(set) var lastError = AppGroup.defaults.string(
        forKey: DebugCaptureSettings.lastErrorStorageKey
    )

    private let worker = DispatchQueue(
        label: "com.slowth.debug-capture.photo-import",
        qos: .utility
    )

    var authorizationText: String {
        switch authorizationStatus {
        case .authorized: return "full access"
        case .limited: return "limited access"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }

    func refresh(importIfPossible: Bool = false) {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        pendingEvents = DebugCaptureFileStore.pendingEventDirectories().count
        pendingBytes = DebugCaptureFileStore.pendingBytes()
        savedEvents = AppGroup.defaults.integer(
            forKey: DebugCaptureSettings.savedEventCountStorageKey
        )
        lastError = AppGroup.defaults.string(forKey: DebugCaptureSettings.lastErrorStorageKey)
        if importIfPossible && DebugCaptureSettings.isEnabled {
            importPending()
        }
    }

    func requestAccessAndImport() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationStatus = status
                if status == .authorized || status == .limited {
                    self.importPending()
                }
            }
        }
    }

    func importPending() {
        guard !isImporting, DebugCaptureSettings.isEnabled else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = status
        guard status == .authorized || status == .limited else { return }
        isImporting = true
        worker.async { [weak self] in
            let result = Self.importAllPending()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImporting = false
                if let error = result.error {
                    DebugCaptureFileStore.setLastError(error)
                } else {
                    DebugCaptureFileStore.setLastError(nil)
                }
                if result.importedEvents > 0 {
                    let total = AppGroup.defaults.integer(
                        forKey: DebugCaptureSettings.savedEventCountStorageKey
                    ) + result.importedEvents
                    AppGroup.defaults.set(
                        total,
                        forKey: DebugCaptureSettings.savedEventCountStorageKey
                    )
                }
                self.refresh()
            }
        }
    }

    func clearPending() {
        worker.async { [weak self] in
            let failure: String?
            do {
                try DebugCaptureFileStore.clearPending()
                failure = nil
            } catch {
                    failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                if let failure {
                    DebugCaptureFileStore.setLastError(failure)
                }
                self?.refresh()
            }
        }
    }

    private static func importAllPending() -> (importedEvents: Int, error: String?) {
        var imported = 0
        do {
            try DebugCaptureFileStore.prepareDirectories()
            let library = PHPhotoLibrary.shared()
            let folder = try ensureFolder(in: library)
            for eventDirectory in DebugCaptureFileStore.pendingEventDirectories() {
                do {
                    let manifest = try loadManifest(from: eventDirectory)
                    let album = try ensureAlbum(
                        for: manifest.kind,
                        in: folder,
                        library: library
                    )
                    try importEvent(
                        manifest,
                        from: eventDirectory,
                        into: album,
                        library: library
                    )
                    DebugCaptureFileStore.archiveManifest(from: eventDirectory)
                    try FileManager.default.removeItem(at: eventDirectory)
                    imported += 1
                } catch {
                    return (imported, error.localizedDescription)
                }
            }
            return (imported, nil)
        } catch {
            return (imported, error.localizedDescription)
        }
    }

    private static func loadManifest(from directory: URL) throws -> DebugCaptureManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DebugCaptureManifest.self, from: data)
        guard manifest.formatVersion == DebugCaptureManifest.currentFormatVersion,
              !manifest.frames.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    private static func ensureFolder(in library: PHPhotoLibrary) throws -> PHCollectionList {
        let identifierKey = "debugCapture.photoFolderIdentifier"
        if let identifier = AppGroup.defaults.string(forKey: identifierKey),
           let folder = PHCollectionList.fetchCollectionLists(
            withLocalIdentifiers: [identifier],
            options: nil
           ).firstObject {
            return folder
        }

        let topLevel = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        var existing: PHCollectionList?
        topLevel.enumerateObjects { collection, _, stop in
            if let folder = collection as? PHCollectionList,
               folder.localizedTitle == DebugCaptureKind.folderTitle {
                existing = folder
                stop.pointee = true
            }
        }
        if let existing {
            AppGroup.defaults.set(existing.localIdentifier, forKey: identifierKey)
            return existing
        }

        var identifier: String?
        try library.performChangesAndWait {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(
                withTitle: DebugCaptureKind.folderTitle
            )
            identifier = request.placeholderForCreatedCollectionList.localIdentifier
        }
        guard let identifier,
              let folder = PHCollectionList.fetchCollectionLists(
                withLocalIdentifiers: [identifier],
                options: nil
              ).firstObject else {
            throw CocoaError(.fileWriteUnknown)
        }
        AppGroup.defaults.set(identifier, forKey: identifierKey)
        return folder
    }

    private static func ensureAlbum(
        for kind: DebugCaptureKind,
        in folder: PHCollectionList,
        library: PHPhotoLibrary
    ) throws -> PHAssetCollection {
        let identifierKey = "debugCapture.photoAlbumIdentifier.\(kind.rawValue)"
        if let identifier = AppGroup.defaults.string(forKey: identifierKey),
           let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
           ).firstObject {
            return album
        }

        let children = PHCollection.fetchCollections(in: folder, options: nil)
        var existing: PHAssetCollection?
        children.enumerateObjects { collection, _, stop in
            if let album = collection as? PHAssetCollection,
               album.localizedTitle == kind.albumTitle {
                existing = album
                stop.pointee = true
            }
        }
        if let existing {
            AppGroup.defaults.set(existing.localIdentifier, forKey: identifierKey)
            return existing
        }

        var identifier: String?
        try library.performChangesAndWait {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                withTitle: kind.albumTitle
            )
            identifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier,
              let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier],
                options: nil
              ).firstObject else {
            throw CocoaError(.fileWriteUnknown)
        }
        try library.performChangesAndWait {
            PHCollectionListChangeRequest(for: folder)?.addChildCollections(
                [album] as NSArray
            )
        }
        AppGroup.defaults.set(identifier, forKey: identifierKey)
        return album
    }

    private static func importEvent(
        _ manifest: DebugCaptureManifest,
        from directory: URL,
        into album: PHAssetCollection,
        library: PHPhotoLibrary
    ) throws {
        for frame in manifest.frames {
            guard FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(frame.filename).path
            ) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }

        try library.performChangesAndWait {
            var placeholders: [PHObjectPlaceholder] = []
            for frame in manifest.frames {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = frame.capturedAt
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = frame.filename
                request.addResource(
                    with: .photo,
                    fileURL: directory.appendingPathComponent(frame.filename),
                    options: options
                )
                if let placeholder = request.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                }
            }
            PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
        }
    }
}
#endif
#endif
