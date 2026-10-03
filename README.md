# Docc2Pdf

A macOS command-line tool that converts Swift DocC documentation archives
(`.doccarchive`) into browsable PDFs.

The generated PDF contains:

- a **cover page** and a **table of contents** with page numbers,
- an **outline** (bookmarks sidebar) that mirrors the documentation's curation,
  including topic groups such as "Essentials" or "Instance Methods",
- **clickable links** between pages, from symbol references, topic lists,
  declarations (type names), breadcrumbs, and the table of contents,
- **running headers** with the current page title, and page numbers,
- searchable, selectable text with syntax-highlighted code, asides, tables,
  images (light, high-resolution variants), and tutorials (steps, code files,
  assessments).

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode 16 or later)

## Building

```bash
swift build -c release
```

The executable is at `.build/release/docc2pdf`. To install it:

```bash
cp .build/release/docc2pdf /usr/local/bin/
```

## Usage

```bash
docc2pdf MyKit.doccarchive
```

This writes `MyKit.pdf` to the current directory. Common options:

| Option | Description |
| --- | --- |
| `-o, --output <path>` | Output PDF path. |
| `--paper <size>` | `letter`, `legal`, `a4`, `a5`, or `WIDTHxHEIGHT` in points. Defaults to your region's paper size. |
| `--margin <points>` | Page margin (default 54). |
| `--font-size <points>` | Body text size (default 10). |
| `--page-breaks auto\|all\|none` | `auto` starts articles, tutorials, and types on a new page and lets members flow; `all` puts every page on a new page; `none` flows everything continuously. |
| `--toc-depth <n>` | Depth of the table of contents (default 1); the outline always contains every page. |
| `--no-toc`, `--no-cover` | Omit the table of contents or the cover page. |
| `--title <text>` | Document title (default: the archive's display name). |
| `--root <path>` | Only include a subtree, e.g. `--root /documentation/mykit/mytype`. Repeatable. |
| `--save-html <path>` | Also write the intermediate HTML, for debugging styles. |
| `-v, --verbose` | Print progress. |

To produce an archive from a Swift package, use the
[Swift-DocC plugin](https://github.com/swiftlang/swift-docc-plugin)
(`swift package generate-documentation`) or Xcode's **Product › Build Documentation**,
then export the archive.

## How it works

1. **Model.** `DocumentationArchive` reads the render JSON in the archive's
   `data/` directory. `DocumentModel` walks the curation tree (topic sections and
   tutorial chapters) starting from the module and tutorial roots, which yields the
   book order. Pages that aren't curated anywhere are appended at the end.
2. **HTML.** `HTMLRenderer` converts every page into one print-styled HTML
   document. References between pages become `#fragment` links; references to
   pages outside the archive become plain text.
3. **Layout.** WebKit lays the document out in a single column as wide as the
   page's text area (1 CSS pixel = 1 point). `PaginationScript` chooses page breaks
   that never cut through a line of text, a table row, or an image. It keeps
   headings with the content that follows, keeps small boxed blocks together, and
   fills in the table of contents page numbers.
4. **Export.** WebKit's PDF export starts a new page every 14,400 points. The
   script inserts invisible spacers at the chosen breaks, so each page starts at a
   multiple of that height, and a single export yields one PDF page per document
   page, with fonts shared across the document. Core Graphics places these pages
   on paper-sized pages and adds the running header, page number, link
   annotations, named destinations, and the outline.

## Development

```bash
swift test
```

The tests build a small synthetic archive. They cover the curation order,
HTML rendering, syntax highlighting, and an end-to-end PDF generation that
checks the outline, link destinations, and per-page text.

## Requirements

The following technologies are needed to build the _docc2pdf_ command-line tool.
The command-line tool can both be built either using _Xcode_ or the _Swift Package Manager_.

- [Xcode 16](https://developer.apple.com/xcode/)
- [Swift 6](https://developer.apple.com/swift/)
- [Swift Package Manager](https://swift.org/package-manager/)

## Copyright

Author: Matthias Zenger (<matthias@objecthub.com>)  
Copyright © 2026 Matthias Zenger. All rights reserved.
