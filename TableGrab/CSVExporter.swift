import Foundation

struct CSVExporter {

    /// Generates a CSV string from a ParsedTable
    static func generateCSV(from table: ParsedTable) -> String {
        var lines: [String] = []

        if !table.headers.isEmpty {
            lines.append(table.headers.map { escapeCSVField($0) }.joined(separator: ","))
        }

        for row in table.rows {
            lines.append(row.map { escapeCSVField($0) }.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    /// Escapes a CSV field per RFC 4180
    static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    /// Saves a CSV string to the user's Downloads folder.
    /// Returns the URL of the saved file.
    @discardableResult
    static func saveToDownloads(csv: String, filename: String) throws -> URL {
        guard let downloadsURL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Could not locate Downloads folder"
            ])
        }
        return try save(csv: csv, filename: filename, to: downloadsURL)
    }

    /// Saves a CSV string to a user-chosen folder.
    /// Existing files are never overwritten — a numeric suffix is added instead.
    /// Returns the URL of the saved file.
    @discardableResult
    static func save(csv: String, filename: String, to directory: URL) throws -> URL {
        let sanitized = sanitizeFilename(filename)
        var targetURL = directory.appendingPathComponent(sanitized)

        // Avoid overwriting existing files
        var counter = 1
        let nameWithoutExt = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let newName = "\(nameWithoutExt) (\(counter)).\(ext)"
            targetURL = directory.appendingPathComponent(newName)
            counter += 1
        }

        try csv.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }

    /// Removes characters that are unsafe for filenames
    private static func sanitizeFilename(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: unsafe).joined(separator: "-")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { sanitized = "export" }
        if !sanitized.hasSuffix(".csv") { sanitized += ".csv" }
        return sanitized
    }
}
