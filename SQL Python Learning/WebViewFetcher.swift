import AppKit
import WebKit

/// Represents a table extracted from a webpage via JavaScript DOM parsing.
struct ExtractedTable: Codable, Sendable {
    let title: String
    let headers: [String]
    let rows: [[String]]
}

/// Uses a WKWebView to load a URL, execute all JavaScript, then extract
/// table data directly from the rendered DOM using the browser's own
/// DOM API — the Swift equivalent of Beautiful Soup.
///
/// This class is retained by the caller (ContentView stores it as @State)
/// to prevent premature deallocation during page loading.
class WebViewFetcher: NSObject, WKNavigationDelegate {

    let webView: WKWebView
    private var hostWindow: NSWindow?
    private var continuation: CheckedContinuation<[ExtractedTable], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var renderDelay: TimeInterval = 3.0
    private var didFinishOnce = false

    override init() {
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    /// Loads the URL, waits for JS to render, then extracts all tables
    /// from the DOM as structured data.
    func fetchTables(from urlString: String, renderDelay: TimeInterval = 3.0, timeout: TimeInterval = 45.0) async throws -> [ExtractedTable] {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        // Cancel any previous fetch
        webView.stopLoading()
        timeoutTask?.cancel()
        continuation = nil

        self.renderDelay = renderDelay
        self.didFinishOnce = false

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.resumeContinuation(with: .failure(URLError(.timedOut)))
            }

            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didFinishOnce else { return }
        didFinishOnce = true

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.renderDelay))
            await self.extractTables()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        resumeContinuation(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        resumeContinuation(with: .failure(error))
    }

    // MARK: - JavaScript DOM Extraction

    private static let extractionScript = """
    (function() {
        var results = [];
        var tables = document.querySelectorAll('table');

        for (var t = 0; t < tables.length; t++) {
            var table = tables[t];

            // Skip tiny/empty tables (nav, layout, etc.)
            var allRows = table.querySelectorAll('tr');
            if (allRows.length < 2) continue;

            // Skip tables that are hidden or have zero dimensions
            var rect = table.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;

            // Determine title
            var title = '';
            var caption = table.querySelector('caption');
            if (caption) {
                title = caption.textContent.trim();
            } else if (table.id) {
                title = table.id
                    .split(/[_-]/)
                    .filter(function(p) { return !/^\\d+$/.test(p); })
                    .map(function(p) { return p.charAt(0).toUpperCase() + p.slice(1); })
                    .join(' ');
            } else if (table.getAttribute('aria-label')) {
                title = table.getAttribute('aria-label').trim();
            }
            if (!title) title = 'Table ' + (results.length + 1);

            // Extract headers from <thead>
            var headers = [];
            var thead = table.querySelector('thead');
            if (thead) {
                var headerRows = thead.querySelectorAll('tr');
                if (headerRows.length > 0) {
                    var lastRow = headerRows[headerRows.length - 1];
                    var cells = lastRow.querySelectorAll('th, td');
                    for (var i = 0; i < cells.length; i++) {
                        headers.push(cells[i].textContent.trim());
                    }
                }
            }

            // Extract data rows
            var dataRows = [];
            var tbody = table.querySelector('tbody');
            var rowSource = tbody ? tbody.querySelectorAll(':scope > tr') : table.querySelectorAll(':scope > tr');

            for (var r = 0; r < rowSource.length; r++) {
                var row = rowSource[r];
                if (row.classList.contains('spacer') ||
                    row.classList.contains('thead') ||
                    row.classList.contains('over_header') ||
                    row.classList.contains('divider')) continue;

                var cells = row.querySelectorAll(':scope > th, :scope > td');
                if (cells.length === 0) continue;

                if (headers.length === 0) {
                    var allTh = true;
                    for (var c = 0; c < cells.length; c++) {
                        if (cells[c].tagName !== 'TH') { allTh = false; break; }
                    }
                    if (allTh) {
                        for (var c = 0; c < cells.length; c++) {
                            headers.push(cells[c].textContent.trim());
                        }
                        continue;
                    }
                }

                var rowData = [];
                for (var c = 0; c < cells.length; c++) {
                    rowData.push(cells[c].textContent.trim());
                }
                dataRows.push(rowData);
            }

            if (dataRows.length === 0) continue;

            if (headers.length === 0) {
                var maxCols = 0;
                for (var r = 0; r < dataRows.length; r++) {
                    if (dataRows[r].length > maxCols) maxCols = dataRows[r].length;
                }
                for (var i = 0; i < maxCols; i++) {
                    headers.push('Column ' + (i + 1));
                }
            }

            for (var r = 0; r < dataRows.length; r++) {
                while (dataRows[r].length < headers.length) {
                    dataRows[r].push('');
                }
                if (dataRows[r].length > headers.length) {
                    dataRows[r] = dataRows[r].slice(0, headers.length);
                }
            }

            results.push({
                title: title,
                headers: headers,
                rows: dataRows
            });
        }

        return JSON.stringify(results);
    })();
    """;

    private func extractTables() async {
        do {
            let result = try await webView.evaluateJavaScript(
                Self.extractionScript,
                in: nil,
                contentWorld: .page
            )

            guard let jsonString = result as? String,
                  let jsonData = jsonString.data(using: .utf8) else {
                resumeContinuation(with: .failure(URLError(.cannotDecodeContentData)))
                return
            }

            let tables = try JSONDecoder().decode([ExtractedTable].self, from: jsonData)
            resumeContinuation(with: .success(tables))
        } catch {
            resumeContinuation(with: .failure(error))
        }
    }

    // MARK: - Continuation & Cleanup

    private func resumeContinuation(with result: Result<[ExtractedTable], Error>) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
