import SwiftUI
import WebKit

// MARK: - WebView Bridge for SwiftUI

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Main View

struct ContentView: View {
    @State private var urlString: String = ""
    @State private var fetchState: FetchState = .idle
    @State private var tables: [ParsedTable] = []
    @State private var expandedTableIDs: Set<UUID> = []
    @State private var showExportSuccess: Bool = false
    @State private var lastExportPath: String = ""
    @State private var fetcher = WebViewFetcher()
    @State private var showWebPreview: Bool = false
    @State private var editingTableID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - URL Input Bar
            HStack {
                TextField("Paste a URL (e.g., https://fbref.com/en/squads/19538871/Manchester-United-Stats)", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { fetchTables() }

                Button("Fetch Tables") {
                    fetchTables()
                }
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fetchState == .loading)
                .keyboardShortcut(.defaultAction)

                // Toggle to show/hide web page preview
                Toggle("Preview", isOn: $showWebPreview)
                    .toggleStyle(.checkbox)
                    .help("Show the webpage while loading")
            }
            .padding()

            Divider()

            // MARK: - Status Bar
            HStack {
                statusView
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if showWebPreview {
                WebViewRepresentable(webView: fetcher.webView)
                    .frame(height: 300)

                Divider()
            }

            // MARK: - Table List
            if tables.isEmpty && fetchState != .loading {
                Spacer()
                emptyStateView
                Spacer()
            } else if !tables.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(tables.enumerated()), id: \.element.id) { index, table in
                            tableCard(for: table, at: index)
                        }
                    }
                    .padding()
                }
            } else {
                Spacer()
            }

            Divider()

            // MARK: - Export Bar
            exportBar
        }
    }

    // MARK: - Status View

    @ViewBuilder
    private var statusView: some View {
        switch fetchState {
        case .idle:
            Label("Enter a URL above to extract HTML tables", systemImage: "globe")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading page and extracting tables…")
            }
        case .loaded:
            Label("Found \(tables.count) table\(tables.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Tables Yet")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Paste a URL and click Fetch Tables to extract\nHTML tables and export them as CSV files.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Table Card

    @ViewBuilder
    private func tableCard(for table: ParsedTable, at index: Int) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expandedTableIDs.contains(table.id) },
            set: { newValue in
                if newValue {
                    expandedTableIDs.insert(table.id)
                } else {
                    expandedTableIDs.remove(table.id)
                }
            }
        )

        DisclosureGroup(isExpanded: isExpanded) {
            if expandedTableIDs.contains(table.id) {
                tablePreview(table)
                    .padding(.top, 4)
            }
        } label: {
            HStack {
                Toggle(isOn: Binding(
                    get: { tables[index].isSelected },
                    set: { tables[index].isSelected = $0 }
                )) {
                    if editingTableID == table.id {
                        TextField("Table name", text: Binding(
                            get: { tables[index].title },
                            set: { tables[index].title = $0 }
                        ))
                        .font(.headline)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { editingTableID = nil }
                    } else {
                        Text(table.title)
                            .font(.headline)
                            .onTapGesture(count: 2) {
                                editingTableID = table.id
                            }
                    }
                }
                .toggleStyle(.checkbox)

                Spacer()

                if editingTableID == table.id {
                    Button("Done") { editingTableID = nil }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button {
                        editingTableID = table.id
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename table")
                }

                Text("\(table.rows.count) rows × \(table.headers.count) cols")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Table Preview

    @ViewBuilder
    private func tablePreview(_ table: ParsedTable) -> some View {
        let maxPreviewRows = 10

        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                if !table.headers.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                            Text(header)
                                .font(.caption.bold())
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(6)
                                .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                        }
                    }
                }

                // Data rows
                ForEach(Array(table.rows.prefix(maxPreviewRows).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.caption)
                                .lineLimit(2)
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(6)
                        }
                    }
                    Divider()
                }

                if table.rows.count > maxPreviewRows {
                    Text("… and \(table.rows.count - maxPreviewRows) more rows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Export Bar

    private var exportBar: some View {
        HStack {
            let selectedCount = tables.filter(\.isSelected).count

            Button(selectedCount == tables.count && !tables.isEmpty ? "Deselect All" : "Select All") {
                let newValue = selectedCount != tables.count
                for i in tables.indices { tables[i].isSelected = newValue }
            }
            .disabled(tables.isEmpty)

            Button("Export Selected (\(selectedCount))") {
                exportTables(tables.filter(\.isSelected))
            }
            .disabled(selectedCount == 0)

            Button("Export All") {
                exportTables(tables)
            }
            .disabled(tables.isEmpty)

            Spacer()

            if showExportSuccess {
                Label("Saved to Downloads", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func fetchTables() {
        var urlToFetch = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlToFetch.isEmpty else { return }

        if !urlToFetch.hasPrefix("http://") && !urlToFetch.hasPrefix("https://") {
            urlToFetch = "https://" + urlToFetch
        }

        fetchState = .loading
        tables = []
        expandedTableIDs = []
        showExportSuccess = false

        Task {
            do {
                let extracted = try await fetcher.fetchTables(from: urlToFetch)

                if extracted.isEmpty {
                    fetchState = .error("No tables found on this page.")
                } else {
                    let parsed = extracted.map { table in
                        ParsedTable(
                            title: table.title,
                            headers: table.headers,
                            rows: table.rows
                        )
                    }
                    tables = parsed
                    if let firstID = parsed.first?.id {
                        expandedTableIDs = [firstID]
                    }
                    fetchState = .loaded
                }
            } catch {
                fetchState = .error("Fetch failed: \(error.localizedDescription)")
            }
        }
    }

    private func exportTables(_ tablesToExport: [ParsedTable]) {
        guard !tablesToExport.isEmpty else { return }

        // Capture the data we need before going off the main thread
        let snapshots = tablesToExport.map { (title: $0.title, headers: $0.headers, rows: $0.rows) }

        Task.detached(priority: .userInitiated) {
            do {
                var lastURL: URL?
                for snapshot in snapshots {
                    let table = ParsedTable(title: snapshot.title, headers: snapshot.headers, rows: snapshot.rows)
                    let csv = CSVExporter.generateCSV(from: table)
                    lastURL = try CSVExporter.saveToDownloads(csv: csv, filename: snapshot.title)
                }

                let finalPath = lastURL?.lastPathComponent ?? ""
                await MainActor.run {
                    lastExportPath = finalPath
                    showExportSuccess = true
                }

                try? await Task.sleep(for: .seconds(4))
                await MainActor.run {
                    showExportSuccess = false
                }
            } catch {
                await MainActor.run {
                    fetchState = .error("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
