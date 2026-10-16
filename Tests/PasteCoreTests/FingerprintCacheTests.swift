import XCTest
import CryptoKit
@testable import PasteCore

final class FingerprintCacheTests: XCTestCase {
    private func legacyFingerprint(_ item: ClipItem) -> String {
        var hash = SHA256()
        func append(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        append(Data(item.kind.rawValue.utf8)); append(Data(item.text.utf8))
        append(Data(String(item.filePaths.count).utf8))
        item.filePaths.forEach { append(Data($0.utf8)) }
        let sorted = item.representations.sorted {
            if $0.itemIndex != $1.itemIndex { return $0.itemIndex < $1.itemIndex }
            if $0.type != $1.type { return $0.type < $1.type }
            return $0.data.lexicographicallyPrecedes($1.data)
        }
        append(Data(String(sorted.count).utf8))
        for value in sorted {
            append(Data(String(value.itemIndex).utf8)); append(Data(value.type.utf8)); append(value.data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func testEveryContentMutationMatchesLegacyHash() {
        var item = ClipItem(text: "hello 世界", kind: .text)
        XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.text = "edited"; XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.kind = .image; XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.representations = [.init(type: "public.png", data: Data([1, 2, 3])), .init(type: "public.tiff", data: Data([4]), itemIndex: 1)]
        XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.representations[0].data.append(5); XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.representations[0].itemIndex = 2; XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.representations[1].type = "different"; XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.representations.reverse(); XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.filePaths.append("/tmp/世界"); XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
        item.filePaths[0] = "/tmp/changed"; XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
    }
    func testMetadataAndOriginalImageDoNotAffectFingerprintOrCopiedValue() {
        let item = ClipItem(text: "", kind: .image, representations: [.init(type: "public.png", data: Data([3]))])
        var copy = item
        copy.id = UUID(); copy.title = "renamed"; copy.sourceName = "App"; copy.sourceBundleID = "org.example"
        copy.createdAt = .distantPast; copy.lastCopiedAt = .distantFuture
        copy.originalRepresentations = [.init(type: "public.png", data: Data([1]))]
        XCTAssertEqual(copy.fingerprint, item.fingerprint)
        copy.representations[0].data = Data([8])
        XCTAssertNotEqual(copy.fingerprint, item.fingerprint)
        XCTAssertEqual(item.fingerprint, legacyFingerprint(item))
    }
    func testCodableRemainsLegacyCompatibleWithoutPersistingCache() throws {
        let item = ClipItem(text: "保存", kind: .text, representations: [.init(type: "public.rtf", data: Data([4, 5]))])
        let data = try JSONEncoder().encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "createdAt", "lastCopiedAt", "title", "text", "kind", "sourceBundleID", "sourceName", "representations", "filePaths"]))
        var decoded = try JSONDecoder().decode(ClipItem.self, from: data)
        XCTAssertEqual(decoded, item); XCTAssertEqual(decoded.fingerprint, legacyFingerprint(item))
        decoded.text = "changed"; XCTAssertEqual(decoded.fingerprint, legacyFingerprint(decoded))
    }
}
