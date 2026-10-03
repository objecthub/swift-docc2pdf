# CLAUDE.md

`docc2pdf` is a macOS command-line tool, written in Swift, that converts a DocC archive (`.doccarchive`) into a paginated PDF. The PDF has a cover page, a table of contents (TOC) with page numbers, an outline (bookmarks), clickable internal and external links, running headers, and page numbers. The README covers user-facing usage. This file records the design, the invariants, and the hard-won findings you need when extending the tool or fixing bugs.

## Commands

```bash
swift build                      # debug build → .build/debug/docc2pdf
swift build -c release           # release build → .build/release/docc2pdf
swift test                       # Swift Testing suite (includes an end-to-end PDF test using WebKit)
.build/debug/docc2pdf Samples/YamlKit.doccarchive -o /tmp/y.pdf -v --save-html /tmp/y.html
```

- `Samples/YamlKit.doccarchive` is a real archive provided by the user: 645 render JSON pages, about 256 PDF pages. Use it as the main regression input. A good release run takes about 1.5 s and produces about 2 MB, with 2,992 links, 840 outline items, and no broken links.
- Debug builds print the WebKit log line "Inspection is enabled by default…" to stderr. It's harmless and doesn't appear in release builds.
- Toolchain: Swift 6 language mode with strict concurrency, macOS 13+, dependencies `swift-argument-parser` (CLI) and `swift-dynamicjson` (the user's own `DynamicJSON` library, which provides the `JSON` type). Write all code warning-free.
- Commit only when the user asks.

## Layout

```
Sources/docc2pdf/Docc2Pdf.swift           CLI (AsyncParsableCommand): option parsing/validation → RenderOptions → PDFGenerator
Sources/DoccToPdfCore/
  JSON+Items.swift           `items` helper (array or []) on DynamicJSON's `JSON` and `JSON?`
  DocumentationArchive.swift Reads data/**/*.json (keyed by lower-cased doc path), metadata.json, index/index.json roots, asset URLs; DoccToPdfError
  DocumentModel.swift        TopicNode/TopicGroup tree in book order (DFS over curation)
  Options.swift              RenderOptions, PaperSize, PageBreakMode
  HTMLRenderer.swift         RenderNode JSON → one HTML document (cover, TOC, one <article> per page)
  Stylesheet.swift           Print CSS (DocC look); 1 CSS px == 1 PDF pt
  SyntaxHighlighter.swift    Line-based highlighter (Swift, C family, scripts, shell-like); DocC archives contain no highlighting
  PaginationScript.swift     JavaScript installed in the page as window.__pager (paginate / layoutBatch / resetBatch)
  PDFGenerator.swift         @MainActor pipeline: WKWebView load → paginate → batched export → Core Graphics composition
Tests/DoccToPdfCoreTests/
  TestArchive.swift          Writes a synthetic 5-page archive (with an uncurated "Orphan" page) to a temp dir
  DoccToPdfCoreTests.swift   Model, renderer, highlighter, options, and end-to-end PDF tests
```

## Pipeline (PDFGenerator.generate)

1. **Model.** `DocumentationArchive` + `DocumentModel(rootPaths:)`.
   - The roots come from `index/index.json` (`interfaceLanguages.swift`, else the first language). Reference roots are sorted before `/tutorials` roots.
   - If there is no index, the roots are the JSON files directly under `data/documentation` and `data/tutorials`.
   - The model does a depth-first traversal of `topicSections[].identifiers` and of tutorial `sections[kind=volume].chapters[].tutorials`. Each identifier is resolved through `page.references[id].url`.
   - A page curated in several places appears once, at its first visit.
   - With no `--root`, pages that are never reached are appended as extra roots. With `--root`, only the requested subtrees are included.
2. **HTML.** `HTMLRenderer.render()` produces one HTML string. It is written to a temporary file and loaded with `loadFileURL(_, allowingReadAccessTo: "/")`, because images are absolute `file://` URLs into the archive.
3. **Load.** The generator waits for `document.fonts.ready` and for all images, then installs `PaginationScript.install`.
4. **Paginate.** `__pager.paginate(contentHeight)` returns `{height, pageCount, linkTargets}`. It also fills in the TOC page numbers.
5. **Render in batches** of `pagesPerBatch` (100). For each batch:
   - `__pager.layoutBatch(first, last, 14400)` inserts spacers and returns `{origin, pages[[start,end]], links, targets, running}`.
   - `webView.pdf(configuration: rect from origin)` exports the batch.
   - `__pager.resetBatch()` removes the spacers.
   - Each exported page is drawn into a `CGContext` PDF page, clipped to the text column, followed by the header and footer, the named destinations, and the link annotations.
6. **Outline.** `CGPDFContextSetOutline`, then `closePDF`, then write the file. PDFKit is **not** used for output; only the tests use it to read PDFs back.

## Key WebKit / Core Graphics findings (verified experimentally — don't relearn these)

- WKWebView works in a plain CLI with Swift async `main`; no NSApplication or window is needed. Everything WebKit-related is `@MainActor`.
- `WKWebView.pdf(configuration:)`:
  - Coordinates are in document space, and regions far outside the view frame work.
  - The export is **cut into PDF pages every 14,400 pt**, measured from `rect.origin`, and the last page is shorter.
  - Each exported page contains only that page's content. Fonts are shared across all pages of one export.
- An export taller than roughly 2.1–2.9 M pt fails with `WKErrorDomain Code=1 "unknown error"`. That's why batches are 100 pages: 100 × 14,400 = 1.44 M.
- **Rejected approaches, and why:**
  - *Drawing one tall band into many clipped pages.* `CGContext.drawPDFPage` copies the **entire** content stream into every page. That produced 18 MB files and put hidden text on pages, which some viewers' search would find.
  - *One `createPDF(rect:)` per page.* Fonts are duplicated in every page (about 8 MB).
  - *PDFKit-written link annotations.* They add an appearance stream to each link, about 550 bytes per link.
  - The current spacer approach gives about 8 KB per page.
- Drawing several pages from the **same** `CGPDFDocument` into one CG context shares their fonts.
- CG links: use `context.setURL(_:for:)` for external links. For internal links, call `context.addDestination(name, at:)` on the target page and `context.setDestination(name, for:)` on the link. Names may be referenced before they are defined. In Swift these are instance methods; the C function names don't compile.
- CG outline format (`CGPDFContextSetOutline`; there is no Swift wrapper, so call the C function):
  - The root is `{Children: [...]}`.
  - Each item is `{kCGPDFOutlineTitle, kCGPDFOutlineDestination: <1-based page number>, kCGPDFOutlineDestinationRect: CGRect(x:0,y:<pdfY>,w:0,h:0).dictionaryRepresentation, kCGPDFOutlineChildren}`.
  - String (named) destinations do **not** work in outlines.
- The web view gets `appearance = .aqua` and the CSS sets `color-scheme: light`, so dark mode never leaks into the output.

## Pagination script (PaginationScript.swift) — how it works

**Boxes.** The script builds vertical intervals called "boxes", sorted by top, then by outermost element (smallest DOM depth):
- **Hard boxes:**
  - each text line: `Range.getClientRects` per text node; `ref` = the text node;
  - images outside running text: `ref` = the enclosing `figure`, or the image itself;
  - `tr` rows shorter than 0.9 of a page.
- **Soft boxes** (`soft: true`):
  - a *head box* `[block.top, firstLine.bottom]` for every block element (`ref` = the block), so breaks land above borders and padding and spacers are inserted before the block;
  - boxed blocks (`pre`, `.declaration`, `.aside`, `.step`, `.assessment`, `figure`) shorter than 0.3 of a page are kept whole;
  - a *tail box* `[lastLine.top, bottom]` for boxed blocks (`ref` = null);
  - `[data-keep-with-next]` element plus the next line (only when shorter than 0.6 of a page).

**Break search.** A break starts at the limit (`start + pageHeight`) and moves up to the top of any box it would cut. If the soft rules would move it more than 30% of a page above the limit, the search is redone with hard boxes only. That fallback prevents keep-with-next chains from cascading. If even a single box is taller than a page, the box is hard-cut at the limit (`ref` null, no spacer).
- **Forced breaks:** `.page-break` elements (cover → TOC, TOC → content, and topic articles according to `PageBreakMode`).
- **Next page start:** the next box after the break. Blank space between pages is skipped.
- Each `breaks[i]` records `{y, ref, mid}`, the DOM position where page *i* starts.

**TOC page numbers.** `paginate` fills `.toc-num[data-target]` with page numbers. If filling them moves any `.page-break`, it paginates again (up to 3 attempts).
- **Invariant:** `.toc-num` spans hold a figure-space placeholder (`\u{2007}`) and have a fixed `flex-basis`.
- Without the placeholder, an empty span changes baseline alignment and shifts the layout by about 12 pt. That bug cut the TOC page in half.

**`layoutBatch`.** Inserts a 1-px spacer (a `div`, or a `tr`/`td` inside tables) before each page's start, measures the result, then sizes the spacer so the page start lands exactly on `origin + k × 14400`. The spacer is measured rather than computed because margins stop collapsing once a spacer is present.
- **Element refs:** the script climbs out of flex/grid parents and out of `td`/`th`/`tbody`, so a spacer never becomes a flex/grid item or a table cell.
- **Text refs:** `lineStart()` uses a binary search over character rects (`bottom > mid`) to find the first character on the line. It walks back through earlier text nodes on the same line, and forward if the node was already split by an earlier break. The text node is split with `splitText` before inserting the spacer.
- No spacer is inserted if the insertion point lies above the previous page's end. The page then continues in the same 14,400-pt chunk, and the composer handles pages that span chunks generically.
- **Outputs:** links (with page index and offset within the page), targets (`id → [page, offsetY]`), and running titles (the last `[data-running-title]` at or above each page's top).

`resolveLinks()` rewrites `#id` links whose target doesn't exist to the page id (the prefix before the first `-`), and removes the link if that doesn't exist either.

## HTML conventions (renderer ↔ script ↔ generator contract)

- **Page ids:** each page is `<article class="topic …" id="tN" data-running-title="…">`, with N following `orderedNodes` order starting at 1. Page ids **never contain `-`**. Sub-anchors are `HTMLRenderer.elementID(base, anchor)`, which produces `tN-<sanitized>`; the fallback logic in the script and the generator depends on this.
- **Other fixed ids:** the cover is `#cover`, the TOC is `#toc` (the outline's "Contents" entry), and topic groups use `group.anchorID` (= `elementID(node.anchorID, section anchor)`).
- **Classes the script relies on:**
  - `page-break` (forced break);
  - `flow` (continuous topic with a top rule), `leaf` (smaller title);
  - `toc-entry`, `toc-num[data-target]`;
  - `.line` (each code line is a block span; join lines without `\n`);
  - `data-keep-with-next` (topic header, headings, and topic-item titles **only when an abstract follows**, otherwise list titles chain);
  - `data-running-title`.
- **Links:** references resolve through `href(forReference:)`:
  - `topic`/`section` pages in the model → `#tN[-fragment]`;
  - `link` → its URL;
  - `download` → a file URL;
  - anything else (unresolvable, or outside a `--root` subset) → plain text.
  - Symbol references render as `<code>`; type identifiers in declarations link with class `tok-type`.
- **Images:** the renderer picks the non-dark variant with the highest scale. A 2x image is emitted as `srcset="url 2x"` with **no `src`**, so it lays out at half size but keeps full resolution. CSS caps images at `max-height: 0.9 × content height`.
- **Titles:** `breakableTitle` inserts `<wbr>` after `.`, `(`, `:`, `,` and at camel-case boundaries. That's why PDFKit text extraction may show a title split, as in "convertFromKebab … Case".
- **`PageBreakMode.auto`:** the first content article breaks if there is a cover or TOC. Otherwise a page starts a new PDF page if its depth is ≤ 1, it isn't a symbol, or it curates children.
- **TOC depth:** a node's groups and children are listed while `node.depth < tocDepth`. Roots are depth 0.

## Render JSON coverage (HTMLRenderer)

- **Blocks:** `paragraph` (a lone image becomes a `figure`), `heading`, `aside` (note/tip/important/warning/experiment/deprecated, custom names), `codeListing`, `unorderedList`, `orderedList` (`start`), `termList`, `table` (header row/column/both, `extendedData` colspan/rowspan with 0 = skip, alignments), `small`, `tabNavigator`, `links`, `row`/`columns`, `video` (poster image plus caption), `thematicBreak`, `dictionaryExample`, `endpointExample`, `step`.
  - Unknown blocks fall back to `content`/`inlineContent`.
- **Inlines:** `text`, `codeVoice`, `emphasis`, `strong`/`inlineHead`, `newTerm`, `sub`/`superscript`, `strikethrough`, `image`, `reference` (overridingTitle, titleInlineContent, isActive), `link`.
- **Primary sections:** `declarations` (shows a language label when not Swift), `content`, `parameters`, `mentions` ("Mentioned In"), `properties`/`rest*`, `restEndpoint`, `attributes`, `possibleValues`.
- **Page sections:** `topicSections` (with `abstract`/`discussion`), `relationshipsSections`, `seeAlsoSections`, `deprecationSummary`, `metadata.platforms` (shown as chips).
- **Tutorials** (`sections`): `hero`, `volume`/`chapters`, `tasks` (contentSection plus stepsSection; a step's `code` is a `file` reference with `highlights`), `assessments`, `callToAction`, `contentAndMedia`.
- **Known gaps:**
  - only the default Swift variant is used (`variantOverrides` and Objective-C are ignored);
  - videos are not embedded;
  - hero and background images are skipped;
  - external links to other archives become plain text.

## Verifying changes

- Run `swift test`. `PDFGenerationTests` checks the following:
  - the outline labels, and that each outline destination lands on a page containing its label;
  - internal links have destination pages;
  - the external URL is preserved;
  - search returns exactly one hit, so there is no hidden duplicated text.
- For layout changes, render pages to PNG and look at them. Use a small Swift script with PDFKit: `page.draw(with: .mediaBox, to:)` into an `NSBitmapImageRep`, or a grid contact sheet. Check page boundaries for cut lines, orphaned headings, and boxes split across pages.
- **Things to inspect after pagination or export changes:**
  - the TOC page (numbers present, nothing cut);
  - pages where long code listings or paragraphs break;
  - a type page followed by flowing members;
  - the file size: about 8 KB per page is normal, so a large jump means content or fonts are duplicated again.
- **Debugging pagination:** add temporary logging inside `computePages` (which box moved the break) and return it in the `paginate` JSON. `window.webkit.messageHandlers` is undefined, so don't use it.
- For a feature-rich test archive, write a `.docc` catalog plus a Swift file, then run:
  - `swiftc -emit-module -emit-module-path sg/M.swiftmodule -module-name M -emit-symbol-graph -emit-symbol-graph-dir sg M.swift`
  - `xcrun docc convert M.docc --additional-symbol-graph-dir sg --output-path M.doccarchive --fallback-display-name M --fallback-bundle-identifier com.example.M`
  - Include asides, tables, `@Row`, `@TabNavigator`, `@Small`, images (`name.png`, `name@2x.png`, `name~dark@2x.png`), and `.tutorial` files with `@Steps`/`@Code`/`@Assessments`.

## Pitfalls

- Render JSON uses `JSON` from **DynamicJSON**; don't reintroduce an ad hoc JSON type.
  - Navigate it with `json["key"]`, `json[index]`, `stringValue`, `intValue`, `boolValue`, `arrayValue`, `objectValue`, `doubleValue`, and `items`.
  - Numbers are `.integer(Int64)` or `.float(Double)`, and `intValue` is nil for floats.
  - `JSON` is `@dynamicMemberLookup`, so a misspelled accessor such as `json.string` still **compiles** as a member lookup and silently returns nil. Always use the `…Value` accessors.
  - Files that touch `JSON` must `import DynamicJSON`.

- Swift 6 strict concurrency:
  - test fixtures can't keep `static let` constants of type `[String: Any]` (use computed properties);
  - `PDFGenerator` and the web view must stay `@MainActor`;
  - the CLI's nonisolated `run()` awaits the main-actor generator.
- JavaScript lives in Swift raw strings (`#"""…"""#`), so regex backslashes need no extra escaping there. `waitForResources` is a plain `"""` string.
- Keep headers and footers inside the margin: they are drawn only when `margin >= 28` and never on the cover (page index 0 when a cover exists). Their positions are relative to the margin (`0.55 × margin` from the top, `0.45 × margin` from the bottom).
- Page numbers in the TOC, footer, and outline are physical PDF page numbers, with the cover counted as page 1.
- Changing CSS that affects line boxes is safe, because pagination measures the real layout. Changing text **after** `paginate` (other than the fixed-width TOC numbers) invalidates the layout.
