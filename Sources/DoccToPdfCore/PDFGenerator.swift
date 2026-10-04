//
//  PDFGenerator.swift
//  Docc2Pdf
//
//  Created by Matthias Zenger on 04/10/2026.
//  Copyright © 2026 Matthias Zenger. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AppKit
import CoreText
import WebKit

/// Converts a DocC archive into a paginated PDF with links, an outline, and a table of contents.
///
/// The pipeline:
/// 1. `DocumentModel` orders the archive's pages following their curation.
/// 2. `HTMLRenderer` turns them into one HTML document as wide as the text column.
/// 3. WebKit lays the document out and `PaginationScript` picks page breaks.
/// 4. For each batch of pages, the script spaces the pages out so WebKit's PDF
///    export produces one PDF page per document page. Core Graphics places those
///    on paper-sized pages and adds running headers, page numbers, link
///    annotations, named destinations, and the outline.
@MainActor
public final class PDFGenerator {
  public struct Summary: Sendable {
    public var pageCount: Int
    public var topicCount: Int
    public var linkCount: Int
  }
  
  public let options: RenderOptions
  private let log: (String) -> Void
  
  /// The height at which WebKit's PDF export starts a new page.
  private let exportPageHeight = 14_400.0
  /// WebKit fails to export very tall regions (somewhere above 2 million points),
  /// so pages are exported in batches.
  private let pagesPerBatch = 100
  
  public init(options: RenderOptions, log: @escaping (String) -> Void = { _ in }) {
    self.options = options
    self.log = log
  }
  
  @discardableResult
  public func generate(archiveURL: URL,
                       outputURL: URL,
                       htmlOutputURL: URL? = nil) async throws -> Summary {
    let archive = try DocumentationArchive(url: archiveURL)
    let model = try DocumentModel(archive: archive, rootPaths: options.rootPaths)
    log("Read \(model.orderedNodes.count) documentation pages from \(archive.displayName).")
    
    let renderer = HTMLRenderer(model: model, options: options)
    let html = renderer.render()
    if let htmlOutputURL {
      try html.write(to: htmlOutputURL, atomically: true, encoding: .utf8)
      log("Wrote intermediate HTML to \(htmlOutputURL.path).")
    }
    let webView = try await loadInWebView(html: html)
    log("Paginating…")
    let pagination: Pagination = try await callScript(
      webView,
      "return __pager.paginate(pageHeight)",
      arguments: ["pageHeight": options.contentHeight])
    log("Rendering \(pagination.pageCount) pages…")
    let output = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: options.paper.width, height: options.paper.height)
    let info: [CFString: Any] = [
      kCGPDFContextTitle: renderer.documentTitle,
      kCGPDFContextCreator: "docc2pdf",
      kCGPDFContextSubject: "Documentation generated from \(archive.url.lastPathComponent)",
    ]
    guard let consumer = CGDataConsumer(data: output),
          let context = CGContext(consumer: consumer,
                                  mediaBox: &mediaBox,
                                  info as CFDictionary) else {
      throw DoccToPdfError.renderingFailed("Could not create a PDF context.")
    }
    var outlineTargets = Set(model.orderedNodes.flatMap { node in
      [node.anchorID] + node.groups.map(\.anchorID)
    })
    outlineTargets.insert("toc")
    let state = RenderState(destinationNames: Set(pagination.linkTargets),
                            outlineTargets: outlineTargets)
    try await renderPages(webView,
                          pagination: pagination,
                          title: renderer.documentTitle,
                          into: context,
                          state: state)
    if let outline = makeOutline(model: model, state: state) {
      CGPDFContextSetOutline(context, outline as CFDictionary)
    }
    context.closePDF()
    guard (output as Data).write(to: outputURL) else {
      throw DoccToPdfError.writeFailed(outputURL)
    }
    return Summary(pageCount: pagination.pageCount,
                   topicCount: model.orderedNodes.count,
                   linkCount: state.linkCount)
  }
  
  // MARK: - Web view
  
  private struct Pagination: Decodable {
    var height: Double
    var pageCount: Int
    /// Ids of all elements that in-document links point to.
    var linkTargets: [String]
  }
  
  private struct Batch: Decodable {
    struct Link: Decodable {
      /// Page index and rectangle within the page's text column (top-down).
      var page: Int
      var x: Double, y: Double, w: Double, h: Double
      var href: String
    }
    /// Document position of the first page; WebKit's export starts here.
    var origin: Double
    /// Start and end document positions of each page after spacing.
    var pages: [[Double]]
    var links: [Link]
    /// Element id → [page index, offset within the page].
    var targets: [String: [Double]]
    var running: [String]
  }
  
  private final class RenderState {
    let destinationNames: Set<String>
    let outlineTargets: Set<String>
    var outlinePositions: [String: (page: Int, y: Double)] = [:]
    var linkCount = 0
    
    init(destinationNames: Set<String>, outlineTargets: Set<String>) {
      self.destinationNames = destinationNames
      self.outlineTargets = outlineTargets
    }
  }
  
  private func loadInWebView(html: String) async throws -> WKWebView {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("docc2pdf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("index.html")
    try html.write(to: file, atomically: true, encoding: .utf8)
    
    let frame = CGRect(x: 0, y: 0, width: options.contentWidth, height: options.contentHeight)
    let webView = WKWebView(frame: frame)
    webView.appearance = NSAppearance(named: .aqua)
    let delegate = NavigationDelegate()
    webView.navigationDelegate = delegate
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      delegate.continuation = continuation
      // Images are referenced by absolute file URLs inside the archive.
      webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }
    webView.navigationDelegate = nil
    _ = try await webView.callAsyncJavaScript(PaginationScript.waitForResources,
                                              contentWorld: .page)
    _ = try await webView.evaluateJavaScript(PaginationScript.install)
    return webView
  }
  
  private func callScript<T: Decodable>(_ webView: WKWebView, _ body: String,
                                        arguments: [String: Any] = [:]) async throws -> T {
    let result = try await webView.callAsyncJavaScript(body,
                                                       arguments: arguments,
                                                       contentWorld: .page)
    guard let json = result as? String, let data = json.data(using: .utf8) else {
      throw DoccToPdfError.renderingFailed("The pagination script returned no result.")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
  
  // MARK: - Page composition
  
  private func renderPages(_ webView: WKWebView, pagination: Pagination, title: String,
                           into context: CGContext, state: RenderState) async throws {
    let paper = options.paper
    let margin = options.margin
    var first = 0
    while first < pagination.pageCount {
      let last = min(first + pagesPerBatch, pagination.pageCount) - 1
      let batch: Batch = try await callScript(
        webView, "return __pager.layoutBatch(first, last, chunk)",
        arguments: ["first": first, "last": last, "chunk": exportPageHeight])
      guard batch.pages.count == last - first + 1, let bottom = batch.pages.last?[1] else {
        throw DoccToPdfError.renderingFailed("Pagination returned an inconsistent layout.")
      }
      let configuration = WKPDFConfiguration()
      configuration.rect = CGRect(x: 0, y: batch.origin, width: options.contentWidth,
                                  height: max(bottom - batch.origin, 1))
      let exported = try await webView.pdf(configuration: configuration)
      _ = try await webView.callAsyncJavaScript("return __pager.resetBatch()", contentWorld: .page)
      guard let provider = CGDataProvider(data: exported as CFData),
            let source = CGPDFDocument(provider), source.numberOfPages > 0 else {
        throw DoccToPdfError.renderingFailed(
          "WebKit did not produce a PDF for pages \(first + 1)–\(last + 1).")
      }
      // Document range covered by each exported page (normally one per document page).
      var sourcePages: [(page: CGPDFPage, top: Double, box: CGRect)] = []
      var top = 0.0
      for number in 1...source.numberOfPages {
        guard let page = source.page(at: number) else {
          continue
        }
        let box = page.getBoxRect(.mediaBox)
        sourcePages.append((page, top, box))
        top += box.height
      }
      let linksByPage = Dictionary(grouping: batch.links, by: \.page)
      let targetsByPage = Dictionary(grouping: batch.targets.filter { $0.value.count == 2 },
                                     by: { Int($0.value[0]) })
      for (offset, placed) in batch.pages.enumerated() {
        let index = first + offset
        let start = placed[0] - batch.origin, end = placed[1] - batch.origin
        context.beginPDFPage(nil)
        for source in sourcePages where source.top < end && source.top + source.box.height > start {
          context.saveGState()
          context.clip(to: CGRect(x: margin, y: paper.height - margin - (end - start),
                                  width: options.contentWidth, height: end - start))
          // Map document position `start` to the top of the text column.
          let shift = paper.height - margin + start - source.box.height - source.top
          context.translateBy(x: margin - source.box.minX, y: shift - source.box.minY)
          context.drawPDFPage(source.page)
          context.restoreGState()
        }
        drawPageFurniture(in: context,
                          pageIndex: index,
                          runningTitle: batch.running[offset],
                          title: title)
        for (id, target) in targetsByPage[index] ?? [] {
          let y = min(paper.height, paper.height - margin - target[1] + 6)
          if state.destinationNames.contains(id) {
            context.addDestination(id as CFString, at: CGPoint(x: 0, y: y))
          }
          if state.outlineTargets.contains(id) {
            state.outlinePositions[id] = (index, y)
          }
        }
        for link in linksByPage[index] ?? [] {
          let rect = CGRect(x: margin + link.x, y: paper.height - margin - link.y - link.h,
                            width: link.w, height: link.h)
          if link.href.hasPrefix("#") {
            let fragment = String(link.href.dropFirst())
            let id = fragment.removingPercentEncoding ?? fragment
            guard state.destinationNames.contains(id) else {
              continue
            }
            context.setDestination(id as CFString, for: rect)
          } else if let url = URL(string: link.href), url.scheme != nil {
            context.setURL(url as CFURL, for: rect)
          } else {
            continue
          }
          state.linkCount += 1
        }
        context.endPDFPage()
      }
      log("Rendered pages \(first + 1)–\(last + 1).")
      first = last + 1
    }
  }
  
  /// Running header (document title and current page title) and page number.
  private func drawPageFurniture(in context: CGContext,
                                 pageIndex: Int,
                                 runningTitle running: String,
                                 title: String) {
    let margin = options.margin
    guard margin >= 28, !(options.includeCover && pageIndex == 0) else {
      return
    }
    let paper = options.paper
    let gray = CGColor(gray: 0.43, alpha: 1)
    let headerBaseline = paper.height - margin * 0.55
    let columnWidth = options.contentWidth
    
    let showsRunning = !running.isEmpty && running != title
    let halfWidth = columnWidth / 2 - 8
    drawText(title, in: context, x: margin, baseline: headerBaseline,
             maxWidth: showsRunning ? halfWidth : columnWidth, alignment: .left, color: gray)
    if showsRunning {
      drawText(running, in: context, x: paper.width - margin, baseline: headerBaseline,
               maxWidth: halfWidth, alignment: .right, color: gray)
    }
    context.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
    context.setLineWidth(0.5)
    context.move(to: CGPoint(x: margin, y: headerBaseline - 6))
    context.addLine(to: CGPoint(x: paper.width - margin, y: headerBaseline - 6))
    context.strokePath()
    
    drawText("\(pageIndex + 1)", in: context, x: paper.width / 2, baseline: margin * 0.45,
             maxWidth: columnWidth, alignment: .center, color: gray)
  }
  
  private enum Alignment {
    case left
    case center
    case right
  }
  
  private func drawText(_ text: String,
                        in context: CGContext,
                        x: Double,
                        baseline: Double,
                        maxWidth: Double,
                        alignment: Alignment,
                        color: CGColor) {
    let size = max(7, options.fontSize * 0.8)
    let font = CTFontCreateUIFontForLanguage(.system, size, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    var line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    if CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth {
      let ellipsis = CTLineCreateWithAttributedString(
        NSAttributedString(string: "…", attributes: attributes))
      line = CTLineCreateTruncatedLine(line, maxWidth, .end, ellipsis) ?? line
    }
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    let originX = switch alignment {
      case .left: x
      case .center: x - width / 2
      case .right: x - width
    }
    context.saveGState()
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: originX, y: baseline)
    CTLineDraw(line, context)
    context.restoreGState()
  }
  
    // MARK: - Outline
  
    /// The outline (bookmarks) in the dictionary format of `CGPDFContextSetOutline`.
  private func makeOutline(model: DocumentModel, state: RenderState) -> [String: Any]? {
    func item(_ title: String, _ id: String, children: [[String: Any]]) -> [String: Any]? {
      guard let position = state.outlinePositions[id] else {
        return nil
      }
      let rect = CGRect(x: 0, y: position.y, width: 0, height: 0)
      var item: [String: Any] = [
        kCGPDFOutlineTitle as String: title,
        kCGPDFOutlineDestination as String: position.page + 1,
        kCGPDFOutlineDestinationRect as String: rect.dictionaryRepresentation,
      ]
      if !children.isEmpty {
        item[kCGPDFOutlineChildren as String] = children
      }
      return item
    }
    func topicItem(_ node: TopicNode) -> [String: Any]? {
      let groups = node.groups.filter { !$0.topics.isEmpty }.compactMap { group in
        item(group.title, group.anchorID, children: group.topics.compactMap(topicItem))
      }
      return item(node.title, node.anchorID, children: groups)
    }
    var top: [[String: Any]] = []
    if options.tocDepth != nil, let contents = item("Contents", "toc", children: []) { 
      top.append(contents)
    }
    top += model.roots.compactMap(topicItem)
    return top.isEmpty ? nil : [kCGPDFOutlineChildren as String: top]
  }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
  var continuation: CheckedContinuation<Void, Error>?
  
  private func finish(_ error: Error?) {
    guard let continuation else {
      return
    }
    self.continuation = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }
  
  func webView(_ webView: WKWebView,
               didFinish navigation: WKNavigation!) {
    finish(nil)
  }
  
  func webView(_ webView: WKWebView,
               didFail navigation: WKNavigation!,
               withError error: Error) {
    finish(error)
  }
  
  func webView(_ webView: WKWebView, didFailProvisionalNavigation
               navigation: WKNavigation!,
               withError error: Error) {
    finish(error)
  }
  
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(DoccToPdfError.renderingFailed("The WebKit content process terminated."))
  }
}

private extension Data {
  func write(to url: URL) -> Bool {
    (try? write(to: url, options: .atomic)) != nil
  }
}
