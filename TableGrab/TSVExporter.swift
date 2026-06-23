import Foundation

/// Exports a ParsedTable to TSV (tab-separated values).
///
/// TSV has no universal quoting mechanism the way CSV does, so any tab or
/// newline characters inside a cell are replaced with a single space to keep
/// the columns aligned. The result pastes cleanly into spreadsheets and is
/// read directly by tools like pandas (`sep="\\t"`).
struct TSVExporter {

    /// Generates a TSV string from a ParsedTable.
    static func generateTSV(from table: ParsedTable) -> String {
        var lines: [String] = []

        if !table.headers.isEmpty {
            lines.append(table.headers.map(sanitizeField).joined(separator: "\t"))
        }

        for row in table.rows {
            lines.append(row.map(sanitizeField).joined(separator: "\t"))
        }

        return lines.joined(separator: "\n")
    }

    /// Replaces characters that would break TSV column/row alignment.
    private static func sanitizeField(_ field: String) -> String {
        return field
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Saves a TSV string to a user-chosen folder.
    /// Existing files are never overwritten — a numeric suffix is added instead.
    /// Returns the URL of the saved file.
    @discardableResult
    static func save(tsv: String, filename: String, to directory: URL) throws -> URL {
        let sanitized = sanitizeFilename(filename)
        var targetURL = directory.appendingPathComponent(sanitized)

        var counter = 1
        let nameWithoutExt = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = directory.appendingPathComponent("\(nameWithoutExt) (\(counter)).\(ext)")
            counter += 1
        }

        try tsv.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }

    /// Removes characters that are unsafe for filenames and ensures a `.tsv` extension.
    private static func sanitizeFilename(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: unsafe).joined(separator: "-")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { sanitized = "export" }
        if !sanitized.lowercased().hasSuffix(".tsv") { sanitized += ".tsv" }
        return sanitized
    }
}
