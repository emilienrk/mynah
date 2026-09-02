// HistoryService.swift
// Whispeur
//
// Manages the persistent history of transcriptions.

import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.whispeur", category: "HistoryService")

@MainActor
@Observable
final class HistoryService {
    var items: [HistoryItem] = []
    
    private let maxItems = 100
    private let fileName = "history.json"
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Whispeur", isDirectory: true)
    }

    /// The directory is injectable so tests never touch the user's real history.
    init(directory: URL = HistoryService.defaultDirectory) {
        self.directory = directory
        loadHistory()
    }
    
    func add(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let newItem = HistoryItem(text: text)
        items.insert(newItem, at: 0)
        
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        
        saveHistory()
    }
    
    /// Keeps the cleared transcriptions in a sibling file: clearing is a single
    /// click away and the history is the only copy of what the user dictated.
    func clearAll() {
        archiveCurrentFile(as: "history-cleared.json")
        items.removeAll()
        saveHistory()
    }
    
    func updateItem(id: UUID, newText: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].text = newText
            saveHistory()
        }
    }
    
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            items = try decoder.decode([HistoryItem].self, from: data)
        } catch {
            logger.error("Failed to load history: \(error)")
            // The next save would overwrite the file we just failed to read, so
            // put it aside first rather than losing the transcriptions for good.
            archiveCurrentFile(as: "history-unreadable.json")
        }
    }

    private func archiveCurrentFile(as name: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        let destination = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: fileURL, to: destination)
        } catch {
            logger.error("Failed to archive history: \(error)")
        }
    }
    
    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(items)
            
            // Ensure directory exists
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save history: \(error)")
        }
    }
}
