import Foundation

/// Exports parsed tables to a single `.xlsx` workbook (one sheet per table).
///
/// Unlike CSV — where Excel has to *guess* where the columns are (and Excel
/// for Mac guesses badly) — an xlsx stores each cell in an explicitly defined
/// row/column. So it opens identically on Excel for Mac, Excel for Windows,
/// Numbers, and Google Sheets with no delimiter ambiguity.
///
/// This is a minimal, dependency-free writer: it builds the Office Open XML
/// (OOXML) parts by hand and packs them into a ZIP container (which is all an
/// .xlsx really is) using the small `ZipWriter` below.
struct XLSXExporter {

    /// Builds a complete .xlsx file (as Data) containing one worksheet per table.
    static func generateWorkbook(from tables: [ParsedTable]) -> Data {
        let sheetNames = uniqueSheetNames(from: tables)

        var zip = ZipWriter()

        // 1. [Content_Types].xml — declares the type of every part in the package
        var overrides = ""
        for i in 0..<tables.count {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """
        zip.add(path: "[Content_Types].xml", data: Data(contentTypes.utf8))

        // 2. _rels/.rels — points the package at the workbook
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        zip.add(path: "_rels/.rels", data: Data(rootRels.utf8))

        // 3. xl/workbook.xml — lists the sheets
        var sheetsXML = ""
        for i in 0..<tables.count {
            sheetsXML += "<sheet name=\"\(escapeAttr(sheetNames[i]))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetsXML)</sheets></workbook>
        """
        zip.add(path: "xl/workbook.xml", data: Data(workbook.utf8))

        // 4. xl/_rels/workbook.xml.rels — maps r:id values to sheet files + styles
        var wbRels = ""
        for i in 0..<tables.count {
            wbRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        wbRels += "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(wbRels)</Relationships>
        """
        zip.add(path: "xl/_rels/workbook.xml.rels", data: Data(workbookRels.utf8))

        // 5. xl/styles.xml — style index 1 is bold (used for header rows)
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>
        """
        zip.add(path: "xl/styles.xml", data: Data(styles.utf8))

        // 6. One worksheet per table
        for (i, table) in tables.enumerated() {
            zip.add(path: "xl/worksheets/sheet\(i + 1).xml", data: Data(worksheetXML(for: table).utf8))
        }

        return zip.finalize()
    }

    /// Saves a workbook of the given tables to a chosen directory.
    /// Existing files are never overwritten — a numeric suffix is added instead.
    @discardableResult
    static func save(tables: [ParsedTable], filename: String, to directory: URL) throws -> URL {
        let data = generateWorkbook(from: tables)
        let sanitized = sanitizeFilename(filename)
        var targetURL = directory.appendingPathComponent(sanitized)

        var counter = 1
        let nameWithoutExt = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = directory.appendingPathComponent("\(nameWithoutExt) (\(counter)).\(ext)")
            counter += 1
        }

        try data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    // MARK: - Worksheet XML

    private static func worksheetXML(for table: ParsedTable) -> String {
        var rowsXML = ""
        var rowIndex = 1

        // Header row (bold, style index 1)
        if !table.headers.isEmpty {
            rowsXML += rowXML(cells: table.headers, rowIndex: rowIndex, styleIndex: 1)
            rowIndex += 1
        }

        // Data rows
        for row in table.rows {
            rowsXML += rowXML(cells: row, rowIndex: rowIndex, styleIndex: nil)
            rowIndex += 1
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rowsXML)</sheetData></worksheet>
        """
    }

    /// Builds one `<row>` of inline-string cells. Every value is stored as a
    /// string to guarantee fidelity (no "007" → 7, no date auto-mangling).
    private static func rowXML(cells: [String], rowIndex: Int, styleIndex: Int?) -> String {
        var cellsXML = ""
        for (c, value) in cells.enumerated() {
            let ref = "\(columnLetter(c))\(rowIndex)"
            let style = styleIndex.map { " s=\"\($0)\"" } ?? ""
            cellsXML += "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeText(value))</t></is></c>"
        }
        return "<row r=\"\(rowIndex)\">\(cellsXML)</row>"
    }

    // MARK: - Helpers

    /// Converts a 0-based column index to an Excel column letter (0→A, 26→AA).
    private static func columnLetter(_ index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            let remainder = n % 26
            result = String(UnicodeScalar(65 + remainder)!) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }

    /// Escapes text content for XML.
    private static func escapeText(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        // Strip control characters that are illegal in XML 1.0
        out = String(out.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar.value >= 0x20
        })
        return out
    }

    /// Escapes a value for use inside an XML attribute.
    private static func escapeAttr(_ s: String) -> String {
        return escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Produces valid, unique Excel sheet names (≤31 chars, no `: \\ / ? * [ ]`).
    private static func uniqueSheetNames(from tables: [ParsedTable]) -> [String] {
        let illegal = CharacterSet(charactersIn: ":\\/?*[]")
        var used = Set<String>()
        var names: [String] = []

        for (i, table) in tables.enumerated() {
            var name = table.title.components(separatedBy: illegal).joined(separator: " ")
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "Sheet \(i + 1)" }
            if name.count > 31 { name = String(name.prefix(31)) }

            // De-duplicate (Excel rejects two sheets with the same name)
            var candidate = name
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                let tag = " (\(suffix))"
                let trimTo = max(0, 31 - tag.count)
                candidate = String(name.prefix(trimTo)) + tag
                suffix += 1
            }
            used.insert(candidate.lowercased())
            names.append(candidate)
        }
        return names
    }

    /// Removes unsafe filename characters and ensures a `.xlsx` extension.
    private static func sanitizeFilename(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: unsafe).joined(separator: "-")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { sanitized = "export" }
        if !sanitized.lowercased().hasSuffix(".xlsx") { sanitized += ".xlsx" }
        return sanitized
    }
}

// MARK: - Minimal ZIP writer (stored / no compression)

/// A tiny ZIP archive builder. An .xlsx file is just a ZIP of XML parts, so
/// this is all that's needed to package one. Entries are stored uncompressed
/// (compression method 0), which Excel reads without issue and keeps the code
/// dependency-free (no Compression-framework plumbing required).
private struct ZipWriter {
    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: Int
    }

    private var output = Data()
    private var entries: [Entry] = []

    /// DOS date/time fixed to 1980-01-01 00:00 (xlsx doesn't care about timestamps).
    private let dosTime: UInt16 = 0
    private let dosDate: UInt16 = 0x0021

    mutating func add(path: String, data: Data) {
        let crc = ZipWriter.crc32(data)
        let offset = output.count
        let nameBytes = Array(path.utf8)

        // Local file header
        output.appendUInt32LE(0x04034b50)        // signature
        output.appendUInt16LE(20)                // version needed
        output.appendUInt16LE(0)                 // flags
        output.appendUInt16LE(0)                 // method 0 = stored
        output.appendUInt16LE(dosTime)
        output.appendUInt16LE(dosDate)
        output.appendUInt32LE(crc)
        output.appendUInt32LE(UInt32(data.count)) // compressed size
        output.appendUInt32LE(UInt32(data.count)) // uncompressed size
        output.appendUInt16LE(UInt16(nameBytes.count))
        output.appendUInt16LE(0)                 // extra length
        output.append(contentsOf: nameBytes)
        output.append(data)

        entries.append(Entry(path: path, data: data, crc: crc, offset: offset))
    }

    mutating func finalize() -> Data {
        let cdStart = output.count

        // Central directory
        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            output.appendUInt32LE(0x02014b50)    // central dir signature
            output.appendUInt16LE(20)            // version made by
            output.appendUInt16LE(20)            // version needed
            output.appendUInt16LE(0)             // flags
            output.appendUInt16LE(0)             // method
            output.appendUInt16LE(dosTime)
            output.appendUInt16LE(dosDate)
            output.appendUInt32LE(entry.crc)
            output.appendUInt32LE(UInt32(entry.data.count))
            output.appendUInt32LE(UInt32(entry.data.count))
            output.appendUInt16LE(UInt16(nameBytes.count))
            output.appendUInt16LE(0)             // extra length
            output.appendUInt16LE(0)             // comment length
            output.appendUInt16LE(0)             // disk number start
            output.appendUInt16LE(0)             // internal attrs
            output.appendUInt32LE(0)             // external attrs
            output.appendUInt32LE(UInt32(entry.offset))
            output.append(contentsOf: nameBytes)
        }

        let cdSize = output.count - cdStart

        // End of central directory record
        output.appendUInt32LE(0x06054b50)
        output.appendUInt16LE(0)                 // disk number
        output.appendUInt16LE(0)                 // disk with central dir
        output.appendUInt16LE(UInt16(entries.count))
        output.appendUInt16LE(UInt16(entries.count))
        output.appendUInt32LE(UInt32(cdSize))
        output.appendUInt32LE(UInt32(cdStart))
        output.appendUInt16LE(0)                 // comment length

        return output
    }

    // Standard IEEE CRC-32
    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
