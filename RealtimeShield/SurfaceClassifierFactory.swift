import Foundation

enum SurfaceClassifierFactory {
    static func make(backend: ModelBackend = ModelSettings.defaultBackend) throws -> any SurfaceClassifying {
        #if DEBUG
        switch backend {
        case .flat11:
            return try FlatClassifier()
        case .v14:
            return try SurfaceClassifier(resourceName: "SurfaceDetectorV14")
        case .v15:
            #if CASCADE_MODEL && os(iOS)
            return try SurfaceClassifier(resourceName: "SurfaceDetectorV15")
            #else
            throw CascadeClassifierError.missing("V15 support in this build")
            #endif
        case .cascadeV10:
            #if CASCADE_MODEL && os(iOS)
            return try CascadeClassifier(candidate: .v10)
            #else
            throw CascadeClassifierError.missing("Cascade V10 support in this build")
            #endif
        case .cascadeV8:
            #if CASCADE_MODEL && os(iOS)
            return try CascadeClassifier(candidate: .v8)
            #else
            throw CascadeClassifierError.missing("Cascade V8 support in this build")
            #endif
        case .cascadeV7:
            #if CASCADE_MODEL && os(iOS)
            return try CascadeClassifier(candidate: .v7)
            #else
            throw CascadeClassifierError.missing("Cascade V7 support in this build")
            #endif
        case .cascadeV6:
            #if CASCADE_MODEL && os(iOS)
            return try CascadeClassifier(candidate: .v6)
            #else
            throw CascadeClassifierError.missing("Cascade V6 support in this build")
            #endif
        }
        #else
        return try FlatClassifier()
        #endif
    }
}
