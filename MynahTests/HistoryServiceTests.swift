// HistoryServiceTests.swift
// MynahTests

import Foundation
import Testing

@MainActor
struct HistoryServiceTests {

    /// A throwaway directory per test: the service otherwise persists into the
    /// user's real Application Support folder.
    private func makeService() -> HistoryService {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MynahTests-\(UUID().uuidString)", isDirectory: true)
        return HistoryService(directory: directory)
    }

    @Test("Adding an item stores it at the front")
    func addItemInsertsAtFront() {
        let service = makeService()

        service.add("first")
        service.add("second")

        #expect(service.items.first?.text == "second")
        #expect(service.items.count == 2)
    }

    @Test("Blank text is not added")
    func blankTextIgnored() {
        let service = makeService()

        service.add("   ")
        service.add("")

        #expect(service.items.isEmpty)
    }

    @Test("clearAll empties the list")
    func clearAllEmptiesList() {
        let service = makeService()
        service.add("something")
        service.clearAll()
        #expect(service.items.isEmpty)
    }

    @Test("List is capped at 100 items")
    func listCappedAt100() {
        let service = makeService()

        for i in 1...110 {
            service.add("item \(i)")
        }

        #expect(service.items.count == 100)
        // Most-recent item should be "item 110"
        #expect(service.items.first?.text == "item 110")
    }

    @Test("Deleting an item removes it and preserves other items")
    func deleteItemRemovesTarget() {
        let service = makeService()
        service.add("first")
        service.add("second")
        service.add("third")

        let secondItem = service.items.first { $0.text == "second" }!
        service.deleteItem(id: secondItem.id)

        #expect(service.items.count == 2)
        #expect(!service.items.contains { $0.text == "second" })
        #expect(service.items.map(\.text) == ["third", "first"])
    }
}
