# Web Stats Scraper

A native macOS app that pulls HTML tables off any web page and exports them as CSV — no Python, no Beautiful Soup, no code. Paste a URL, click **Fetch Tables**, pick the tables you want, and save them as spreadsheets.

Built for getting to data quickly: sports stats, reference tables, anything rendered as an HTML `<table>`.

## Screenshots

| Paste a URL to start | Tables extracted with detected names, ready to export |
| --- | --- |
| ![Empty state](screenshots/empty-state.png) | ![Results](screenshots/results.png) |

## How it works

Instead of downloading raw HTML and parsing it (the Beautiful Soup approach), the app loads the page in a real browser engine (`WKWebView`), lets the page's JavaScript run, and then reads the tables straight out of the rendered DOM. This means it handles modern sites that build their tables with JavaScript after the page loads — which trips up traditional scrapers.

## Features

- **Paste a URL and fetch** — extracts every meaningful `<table>` on the page
- **Live preview** — see each table's columns and rows before exporting
- **Pick what you want** — checkboxes per table, plus a **Select All / Deselect All** toggle
- **Rename tables** — double-click a title to give the export a sensible filename
- **CSV export** — RFC 4180–compliant, with a folder picker so you choose where files land
- **Safe saves** — never overwrites an existing file (adds a numeric suffix instead)
- **Optional web preview** — toggle a live view of the page while it loads

## Requirements

- macOS (Apple Silicon or Intel)
- Xcode (to build from source)

## Building

1. Open `Web Stats Scraper.xcodeproj` in Xcode
2. Select the **Web Stats Scraper** scheme
3. Build and run (⌘R)

## Usage

1. Paste a URL into the field at the top (e.g. a stats or reference page)
2. Click **Fetch Tables** and wait for the page to load and render
3. Review the tables that were found in the preview list
4. Check the ones you want, optionally rename them
5. Click **Export Selected** (or **Export All**) and choose a destination folder

## Bot checks & the Preview toggle

Some sites (Cloudflare-protected pages like FBref, and others with anti-bot
protection) put up a challenge — a "Verifying you are human" / "Just a moment…"
screen — before the real page loads. When that happens, the app may find no
tables, or only the challenge page's content.

The fix is the **Preview** checkbox in the top-right:

1. Turn on **Preview** to show the live web page while it loads.
2. Click **Fetch Tables**. If a bot check appears, complete it in the preview
   (e.g. tick the "I'm human" box) just like you would in a normal browser.
3. Once the real page finishes loading, the tables will be extracted.

Because the app uses a real browser engine (`WKWebView`), these challenges
behave exactly as they do in Safari — so passing them once in the preview lets
the page through. Leaving Preview on is the simplest way to handle any site
that occasionally throws up a verification step.

## Project structure

| File | Purpose |
| --- | --- |
| `ContentView.swift` | The SwiftUI interface — URL bar, table list, preview, export |
| `WebViewFetcher.swift` | Loads the page in `WKWebView` and extracts tables from the DOM |
| `CSVExporter.swift` | Turns extracted tables into CSV and saves them to disk |
| `Models.swift` | Data models for parsed tables and fetch state |

## Notes

This is a personal tool, built for quick, friendly table extraction rather than as a general-purpose scraping product. It works best on pages where the data lives in real HTML `<table>` elements.
