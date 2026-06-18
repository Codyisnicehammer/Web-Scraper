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
        // Convert a camelCase, snake_case, or kebab-case string to Title Case
        function formatName(str) {
            return str
                .replace(/([a-z])([A-Z])/g, '$1 $2')
                .split(/[_\\-\\s]+/)
                .filter(function(p) { return p.length > 0 && !/^\\d+$/.test(p); })
                .map(function(p) { return p.charAt(0).toUpperCase() + p.slice(1).toLowerCase(); })
                .join(' ');
        }

        // Find the best human-readable title for a table by checking, in order:
        // caption, ARIA/data attributes, nearby title divs, preceding headings,
        // ancestor headings/labels/active tabs, and finally ids/class names.
        function detectTitle(table, resultIndex) {
            var title = '';

            // 1. <caption> inside the table
            var caption = table.querySelector('caption');
            if (caption) title = caption.textContent.trim();

            // 2. aria-label, data-title, or summary on the table itself
            if (!title) title = (table.getAttribute('aria-label') || '').trim();
            if (!title) title = (table.getAttribute('data-title') || '').trim();
            if (!title) title = (table.getAttribute('summary') || '').trim();

            // 3. A title div in a nearby ancestor (e.g. ESPN's .Table__Title)
            if (!title) {
                var anc = table.parentElement;
                var td = 0;
                while (anc && td < 4) {
                    var titleDiv = anc.querySelector(':scope > .Table__Title, :scope > .table-title, :scope > [class*="title" i]');
                    if (titleDiv) {
                        var txt = titleDiv.textContent.trim();
                        if (txt && txt.length < 60) { title = txt; break; }
                    }
                    anc = anc.parentElement;
                    td++;
                }
            }

            // 4. A heading among the table's preceding siblings
            if (!title) {
                var prev = table.previousElementSibling;
                var attempts = 0;
                while (prev && attempts < 5) {
                    if (/^H[1-6]$/.test(prev.tagName)) { title = prev.textContent.trim(); break; }
                    var innerH = prev.querySelector('h1, h2, h3, h4, h5, h6');
                    if (innerH) { title = innerH.textContent.trim(); break; }
                    prev = prev.previousElementSibling;
                    attempts++;
                }
            }

            // 5. Walk up ancestors looking for headings, labels, or active tabs
            if (!title) {
                var ancestor = table.parentElement;
                var depth = 0;
                while (ancestor && depth < 8) {
                    var aLabel = (ancestor.getAttribute('aria-label') || '').trim();
                    if (aLabel) { title = aLabel; break; }
                    var dTitle = (ancestor.getAttribute('data-title') || '').trim();
                    if (dTitle) { title = dTitle; break; }

                    // Headings that are direct children of this ancestor
                    var directHeadings = ancestor.querySelectorAll(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6');
                    if (directHeadings.length > 0) {
                        var best = null;
                        for (var h = 0; h < directHeadings.length; h++) {
                            if (table.compareDocumentPosition(directHeadings[h]) & 2) best = directHeadings[h];
                        }
                        title = (best || directHeadings[0]).textContent.trim();
                        break;
                    }

                    // Any heading inside this ancestor not belonging to another table
                    var deepHeadings = ancestor.querySelectorAll('h1, h2, h3, h4, h5, h6');
                    if (deepHeadings.length > 0) {
                        var bestDeep = null;
                        for (var h2 = 0; h2 < deepHeadings.length; h2++) {
                            var hdg = deepHeadings[h2];
                            if (hdg.closest('table')) continue;
                            if (table.compareDocumentPosition(hdg) & 2) bestDeep = hdg;
                        }
                        if (bestDeep) { title = bestDeep.textContent.trim(); break; }
                        for (var h3 = 0; h3 < deepHeadings.length; h3++) {
                            if (!deepHeadings[h3].closest('table')) { title = deepHeadings[h3].textContent.trim(); break; }
                        }
                        if (title) break;
                    }

                    // An active tab label
                    var activeTab = ancestor.querySelector('.active[role="tab"], [aria-selected="true"], .tab.active, .nav-link.active');
                    if (activeTab) { title = activeTab.textContent.trim(); break; }

                    ancestor = ancestor.parentElement;
                    depth++;
                }
            }

            // 6. The table's own id, formatted
            if (!title && table.id) title = formatName(table.id);

            // 7. A descriptive ancestor id or class
            if (!title) {
                var anc2 = table.parentElement;
                var ad = 0;
                while (anc2 && ad < 6) {
                    if (anc2.id && !/^(root|app|main|content|wrapper|container|page|body)$/i.test(anc2.id)) {
                        title = formatName(anc2.id); break;
                    }
                    if (typeof anc2.className === 'string' && anc2.className) {
                        var classes = anc2.className.split(/\\s+/).filter(function(c) {
                            return c.length > 3 &&
                                !/^(col|row|container|wrapper|section|div|block|content|main|page|app|flex|grid|responsive|pinned|scrollable)$/i.test(c) &&
                                !/^(d|p|m|mt|mb|ml|mr|mx|my|pt|pb|pl|pr|px|py)-/i.test(c);
                        });
                        if (classes.length > 0) { title = formatName(classes[0]); break; }
                    }
                    anc2 = anc2.parentElement;
                    ad++;
                }
            }

            // 8. The table's own class names
            if (!title && typeof table.className === 'string' && table.className) {
                var tClasses = table.className.split(/\\s+/).filter(function(c) {
                    return c.length > 2 && !/^(table|data|stats|responsive|striped|hover|bordered)$/i.test(c);
                });
                if (tClasses.length > 0) title = formatName(tClasses[0]);
            }

            // 9. Fallback — number the table
            if (!title) title = 'Table ' + (resultIndex + 1);

            title = title.replace(/\\s+/g, ' ').trim();
            if (title.length > 100) title = title.substring(0, 100).trim();
            return title;
        }

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

            // Determine title (searches caption, ARIA labels, nearby
            // headings, tab names, ids, and class names)
            var title = detectTitle(table, results.length);

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
