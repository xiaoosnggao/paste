import XCTest
@testable import PasteCore

final class EnrichmentTests: XCTestCase {
    private func image(enrichment: ClipEnrichment? = nil) -> ClipItem {
        ClipItem(text: "", kind: .image, representations: [.init(type: "public.png", data: Data([1, 2, 255]))], originalRepresentations: [.init(type: "public.png", data: Data([0, 5, 9]))], enrichment: enrichment)
    }
    private func translation(_ source: String = "原文", result: String = "Translated") -> ClipTranslation {
        .init(sourceText: source, translatedText: result, sourceLanguage: "zh", targetLanguage: "en", model: "glm-4-flash")
    }
    func testLegacyV1DecodesWithoutEnrichment() throws {
        let item = image()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "enrichment")
        let decoded = try JSONDecoder().decode(ClipItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.enrichment)
        XCTAssertEqual(decoded.representations, item.representations)
        XCTAssertEqual(decoded.fingerprint, item.fingerprint)
    }
    func testDerivedMetadataDoesNotAlterImageOrFingerprint() {
        let item = image()
        var enriched = item
        enriched.enrichment = .init(ocr: .init(text: "原文"), translation: translation())
        XCTAssertEqual(enriched.fingerprint, item.fingerprint)
        XCTAssertEqual(enriched.representations, item.representations)
        XCTAssertEqual(enriched.originalRepresentations, item.originalRepresentations)
    }
    func testTranslationStalenessUsesNonemptyOCRThenClipboardText() {
        var item = ClipItem(text: "原文", kind: .text)
        XCTAssertFalse(item.translationIsStale)
        item.enrichment = .init(translation: translation())
        XCTAssertFalse(item.translationIsStale)
        item.text = "Changed"
        XCTAssertTrue(item.translationIsStale)
        item.enrichment?.ocr = .init(text: "原文")
        XCTAssertFalse(item.translationIsStale)
        item.enrichment?.ocr = .init(text: " \n")
        XCTAssertTrue(item.translationIsStale)
    }
    func testDuplicateCapturePreservesExistingEnrichment() {
        let item = image(enrichment: .init(ocr: .init(text: "原文"), translation: translation()))
        let duplicate = image(enrichment: .init(ocr: .init(text: "new result")))
        let captured = SnapshotOperations.capture(duplicate, in: .init(items: [item]))
        XCTAssertEqual(captured.items.count, 1)
        XCTAssertEqual(captured.items[0].id, item.id)
        XCTAssertEqual(captured.items[0].enrichment, item.enrichment)
    }
    func testSearchMatchesOCRAndTranslationWithoutReplacingText() {
        let item = image(enrichment: .init(ocr: .init(text: "发票编号 invoice"), translation: translation(result: "Receipt total")))
        let snapshot = ClipboardSnapshot(items: [item])
        for query in ["发票", "INVOICE", "receipt"] {
            XCTAssertEqual(SnapshotOperations.filteredItems(in: snapshot, query: query, pinboardID: nil, filter: .init()).map(\.id), [item.id])
        }
        XCTAssertEqual(item.text, "")
    }
    func testEnrichmentSaveExportImportRoundtrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SnapshotRepository(directory: directory)
        let snapshot = ClipboardSnapshot(items: [image(enrichment: .init(ocr: .init(text: "原文"), translation: translation()))])
        try repository.save(snapshot)
        XCTAssertEqual(try repository.load(), snapshot)
        let exported = directory.appendingPathComponent("backup.json")
        try repository.export(snapshot, to: exported)
        XCTAssertEqual(try repository.importSnapshot(from: exported), snapshot)
    }
    func testReplaceUndoRedoEnrichmentPreservesLaterCapture() {
        let item = image()
        let before = ClipboardSnapshot(items: [item])
        var edited = item; edited.enrichment = .init(ocr: .init(text: "原文"), translation: translation())
        let after = SnapshotOperations.replaceItem(edited, in: before)
        let captured = ClipItem(text: "Later capture", kind: .text)
        let current = SnapshotOperations.capture(captured, in: after)
        let undone = SnapshotOperations.undoChange(before: before, after: after, in: current)
        XCTAssertNil(undone.items.first(where: { $0.id == item.id })?.enrichment)
        XCTAssertEqual(undone.items.first?.id, captured.id)
        let redone = SnapshotOperations.undoChange(before: after, after: before, in: undone)
        XCTAssertEqual(redone.items.first(where: { $0.id == item.id })?.enrichment, edited.enrichment)
        XCTAssertEqual(redone.items.first?.id, captured.id)
    }
    func testUndoOCRKeepsLaterTranslation() {
        let item = image()
        let before = ClipboardSnapshot(items: [item])
        var changed = item; changed.enrichment = .init(ocr: .init(text: "原文"))
        let after = ClipboardSnapshot(items: [changed])
        changed.enrichment?.translation = translation()
        let undone = SnapshotOperations.undoChange(before: before, after: after, in: .init(items: [changed]))
        XCTAssertNil(undone.items[0].enrichment?.ocr)
        XCTAssertEqual(undone.items[0].enrichment?.translation, changed.enrichment?.translation)
    }
    func testOversizedAndMalformedEnrichmentRejected() {
        let repository = SnapshotRepository(directory: FileManager.default.temporaryDirectory)
        let giant = String(repeating: "x", count: 2 * 1024 * 1024 + 1)
        let values: [ClipEnrichment] = [
            .init(ocr: .init(text: giant)),
            .init(translation: translation(giant)),
            .init(translation: translation(result: giant)),
            .init(ocr: .init(text: "x", provider: String(repeating: "p", count: 1025))),
            .init(translation: .init(sourceText: "x", translatedText: "y", sourceLanguage: String(repeating: "x", count: 65), targetLanguage: "en", model: "glm")),
            .init(translation: .init(sourceText: "x", translatedText: "y", sourceLanguage: "zh", targetLanguage: "en", model: String(repeating: "m", count: 1025)))
        ]
        for enrichment in values { XCTAssertThrowsError(try repository.validate(.init(items: [image(enrichment: enrichment)]))) }
    }
    func testEnrichmentCountsTowardRetentionAndRepositoryTotal() {
        var large = image()
        large.representations = [.init(type: "public.png", data: Data(count: 47 * 1024 * 1024))]
        large.originalRepresentations = nil
        large.enrichment = .init(ocr: .init(text: String(repeating: "x", count: 2 * 1024 * 1024)))
        XCTAssertTrue(SnapshotOperations.prune(.init(items: [large])).items.isEmpty)
        large.representations = [.init(type: "public.png", data: Data(count: 63 * 1024 * 1024))]
        XCTAssertThrowsError(try SnapshotRepository(directory: FileManager.default.temporaryDirectory).validate(.init(items: [large])))
    }
}
