import XCTest
@testable import CascadeRuntime

final class MetadataTests: XCTestCase {
    func document() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "CascadeMetadata", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    func decode(_ object: [String: Any]) throws -> CascadeModelMetadata {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CascadeModelMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testSnakeCaseMetadataDecodes() throws {
        let metadata = try decode(document())
        XCTAssertEqual(metadata.modelVersion, "surface-cascade-v2")
        XCTAssertEqual(metadata.policy.temporal.windowFrames, 5)
        XCTAssertNoThrow(try metadata.validate())
    }
    func testCreatorMustMatchVersionStageAndDigest() throws {
        let metadata = try decode(document())
        let valid = ["cascade_stage": "router", "cascade_version": metadata.modelVersion,
                     "checkpoint_sha256": metadata.components["router"]!.checkpointSha256]
        XCTAssertNoThrow(try metadata.validateCreator(valid, stage: "router"))
        for key in valid.keys {
            var wrong = valid
            wrong[key] = "wrong"
            XCTAssertThrowsError(try metadata.validateCreator(wrong, stage: "router"))
            wrong[key] = nil
            XCTAssertThrowsError(try metadata.validateCreator(wrong, stage: "router"))
        }
    }

    func testRejectsEmptyVersion() throws {
        var object = try document()
        object["model_version"] = "  "
        XCTAssertThrowsError(try decode(object).validate())
    }

    func testRejectsUnexpectedResourceIdentity() throws {
        var object = try document()
        var components = object["components"] as! [String: [String: Any]]
        components["router"]!["resource"] = "../AppRouter"
        object["components"] = components
        XCTAssertThrowsError(try decode(object).validate())
    }

    func testRejectsDigestWithTrailingNewline() throws {
        var object = try document()
        var components = object["components"] as! [String: [String: Any]]
        components["router"]!["checkpoint_sha256"] = String(repeating: "a", count: 64) + "\n"
        object["components"] = components
        XCTAssertThrowsError(try decode(object).validate())
    }

    func testRejectsNonHexCheckpointDigest() throws {
        var object = try document()
        var components = object["components"] as! [String: [String: Any]]
        components["router"]!["checkpoint_sha256"] = String(repeating: "z", count: 64)
        object["components"] = components
        XCTAssertThrowsError(try decode(object).validate())
    }
}
