import Foundation

// MARK: - Data Models

struct ParsedTable: Identifiable {
    let id = UUID()
    var title: String
    var headers: [String]
    var rows: [[String]]
    var isSelected: Bool = true
}

enum FetchState: Equatable {
    case idle
    case loading
    case loaded
    case error(String)
    /// No tables found and the page looks like a bot-check / verification wall.
    case botChallenge
}
