import XCTest

/// Optional private exports are unverified when absent; invalid supplied paths fail.
func requiredModelBundlePath(_ key: String) throws -> String {
    guard let path = ProcessInfo.processInfo.environment[key] else {
        throw XCTSkip("Unverified private model scenario: set \(key)")
    }
    return path
}
