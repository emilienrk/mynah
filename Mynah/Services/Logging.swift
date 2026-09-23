// Logging.swift
// Mynah
//
// Unified logging, following Apple's convention: the bundle identifier as the
// subsystem, one category per component. Read with Console.app or
// `log stream --predicate 'subsystem == "com.mynah.Mynah"'`.

import Foundation
import os

extension Logger {
    init(category: String) {
        self.init(subsystem: Bundle.main.bundleIdentifier ?? "com.mynah.Mynah", category: category)
    }
}
