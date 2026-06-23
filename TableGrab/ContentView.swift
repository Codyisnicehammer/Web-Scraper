import SwiftUI
import WebKit
import AppKit

// MARK: - WebView Bridge for SwiftUI

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    /// Wrap the shared web view in a plain container managed by Auto Layout.
    /// Returning the live `WKWebView` directly lets its (fixed-frame, still
    /// rendering) layout fight SwiftUI's `NSHostingView`, which can spin the
    /// view graph into a continuous update loop and hang the app. Pinning it
    /// inside a container decouples the web view's sizing from SwiftUI.
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.removeFromSuperview()
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
            if fetchState == .botChallenge {
                Spacer()
                botChallengeView
                Spacer()
            } else if tables.isEmpty && fetchState != .loading {
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
        case .botChallenge:
            Label("This site is showing a bot check — see below", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
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
            Text("Paste a URL and click Fetch Tables to extract\nHTML tables and export them as CSV or Excel files.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Bot Challenge Prompt

    @ViewBuilder
    private var botChallengeView: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("No tables found — this site has a bot check")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            if showWebPreview {
                Text("Solve the “verify you are human” check in the preview above,\nthen click Retry once the real page loads.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    fetchTables()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .command)
            } else {
                Text("The page is asking to verify you're human before it loads.\nTurn on the live preview, clear the check, and try again.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showWebPreview = true
                    fetchTables()
                } label: {
                    Label("Show Preview & Retry", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("Tip: leave Preview on for sites like FBref that often show these checks.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: 460)
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
        let maxPreviewCols = 12
        // Bound both dimensions so a very wide or tall table can't blow up
        // SwiftUI's layout (the full data is still exported in full).
        let colCount = max(table.headers.count, table.rows.first?.count ?? 0)
        let shownCols = min(colCount, maxPreviewCols)
        let extraCols = colCount - shownCols

        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                if !table.headers.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(0..<shownCols, id: \.self) { i in
                            Text(i < table.headers.count ? table.headers[i] : "")
                                .font(.caption.bold())
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(6)
                                .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                        }
                        if extraCols > 0 {
                            Text("+\(extraCols) more")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 80, alignment: .leading)
                                .padding(6)
                        }
                    }
                }

                // Data rows
                ForEach(Array(table.rows.prefix(maxPreviewRows).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(0..<shownCols, id: \.self) { i in
                            Text(i < row.count ? row[i] : "")
                                .font(.caption)
                                .lineLimit(2)
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(6)
                        }
                        if extraCols > 0 {
                            Text("…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 80, alignment: .leading)
                                .padding(6)
                        }
                    }
                    Divider()
                }

                if extraCols > 0 {
                    Text("… and \(extraCols) more column\(extraCols == 1 ? "" : "s") (full data is exported)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
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

            Button("Export CSV (\(selectedCount))") {
                exportTables(tables.filter(\.isSelected))
            }
            .disabled(selectedCount == 0)

            Button("Export Excel (\(selectedCount))") {
                exportExcel(tables.filter(\.isSelected))
            }
            .disabled(selectedCount == 0)

            Spacer()

            if showExportSuccess {
                Label("Saved to \(lastExportPath)", systemImage: "checkmark.circle.fill")
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
            } catch WebViewFetcherError.botChallenge {
                fetchState = .botChallenge
            } catch {
                fetchState = .error("Fetch failed: \(error.localizedDescription)")
            }
        }
    }

    private func exportTables(_ tablesToExport: [ParsedTable]) {
        guard !tablesToExport.isEmpty else { return }

        // Ask the user where to save. Choosing a folder grants the sandbox
        // write access to that location.
        guard let destination = chooseExportFolder(fileCount: tablesToExport.count) else { return }

        // Capture the data we need before going off the main thread
        let snapshots = tablesToExport.map { (title: $0.title, headers: $0.headers, rows: $0.rows) }

        Task.detached(priority: .userInitiated) {
            do {
                for snapshot in snapshots {
                    let table = ParsedTable(title: snapshot.title, headers: snapshot.headers, rows: snapshot.rows)
                    let csv = CSVExporter.generateCSV(from: table)
                    try CSVExporter.save(csv: csv, filename: snapshot.title, to: destination)
                }

                let folderName = destination.lastPathComponent
                await MainActor.run {
                    lastExportPath = folderName
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

    /// Exports the given tables as a single .xlsx workbook (one sheet per table).
    /// Uses the same folder-picker flow as CSV export (NSOpenPanel), which is
    /// the sandbox-friendly path that works reliably in this app.
    private func exportExcel(_ tablesToExport: [ParsedTable]) {
        guard !tablesToExport.isEmpty else { return }

        // Ask the user for a destination folder (grants sandbox write access).
        guard let destination = chooseExportFolder(fileCount: 1) else { return }

        let snapshots = tablesToExport.map { (title: $0.title, headers: $0.headers, rows: $0.rows) }
        let workbookName = tablesToExport.count == 1 ? tablesToExport[0].title : "Web Stats Export"

        Task.detached(priority: .userInitiated) {
            do {
                let tables = snapshots.map { ParsedTable(title: $0.title, headers: $0.headers, rows: $0.rows) }
                let savedURL = try XLSXExporter.save(tables: tables, filename: workbookName, to: destination)

                let name = savedURL.lastPathComponent
                await MainActor.run {
                    lastExportPath = name
                    showExportSuccess = true
                }
                try? await Task.sleep(for: .seconds(4))
                await MainActor.run { showExportSuccess = false }
            } catch {
                await MainActor.run {
                    fetchState = .error("Excel export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Presents a folder-chooser panel and returns the selected directory, or nil if cancelled.
    private func chooseExportFolder(fileCount: Int) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to save the exported file\(fileCount == 1 ? "" : "s")"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        return panel.runModal() == .OK ? panel.url : nil
    }
}

#Preview {
    ContentView()
}
