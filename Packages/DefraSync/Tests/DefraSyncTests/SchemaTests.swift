import XCTest
@testable import DefraSync

final class SchemaTests: XCTestCase {

    func test_sdl_contains_each_collection() {
        for type in [DefraTypeName.sleepSession, DefraTypeName.dailyMetric,
                     DefraTypeName.journal, DefraTypeName.workout, DefraTypeName.appleDaily] {
            XCTAssertTrue(DefraSchema.sdl.contains("type \(type)"),
                          "SDL missing type \(type)")
        }
    }

    func test_sdl_every_type_has_naturalKey_unique_index() {
        // Crude but effective: each declared type must be followed (within a few lines) by the
        // @index(unique: true) marker on naturalKey.
        let types = [DefraTypeName.sleepSession, DefraTypeName.dailyMetric,
                     DefraTypeName.journal, DefraTypeName.workout, DefraTypeName.appleDaily]
        for type in types {
            guard let typeRange = DefraSchema.sdl.range(of: "type \(type)") else {
                XCTFail("SDL missing \(type)"); continue
            }
            let after = DefraSchema.sdl[typeRange.upperBound...]
            let keyOK = after.contains("naturalKey: String @index(unique: true)")
                && after.prefix(400).contains("naturalKey")
            XCTAssertTrue(keyOK, "\(type) missing unique naturalKey index")
        }
    }

    func test_hash_is_deterministic() {
        let a = DefraSchema.sha256Hex
        let b = DefraSchema.sha256Hex
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }
}
