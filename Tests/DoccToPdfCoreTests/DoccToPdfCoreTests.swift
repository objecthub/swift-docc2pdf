//
//  DoccToPdfCoreTests.swift
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

import DynamicJSON
import Foundation
import PDFKit
import Testing
@testable import DoccToPdfCore

@Suite struct ArchiveAndModelTests {
  @Test func readsMetadataAndRoots() throws {
    let fixture = try TestArchive()
    defer { fixture.remove() }
    let archive = try DocumentationArchive(url: fixture.url)
    #expect(archive.displayName == "TestKit")
    #expect(archive.bundleIdentifier == "com.example.TestKit")
    #expect(archive.rootPaths() == ["/documentation/testkit"])
    #expect(archive.contains(path: "doc://TestKit/documentation/TestKit/Widget#overview"))
  }
  
  @Test func followsCurationAndAppendsUncuratedPages() throws {
    let fixture = try TestArchive()
    defer { fixture.remove() }
    let model = try DocumentModel(archive: DocumentationArchive(url: fixture.url))
    #expect(model.orderedNodes.map(\.title)
      == ["TestKit", "Getting Started", "Widget", "size", "Orphan"])
    #expect(model.orderedNodes.map(\.depth) == [0, 1, 1, 2, 0])
    #expect(model.roots.map(\.title) == ["TestKit", "Orphan"])
    let root = model.roots[0]
    #expect(root.groups.map(\.title) == ["Essentials"])
    #expect(root.groups[0].anchorID == "t1-Essentials")
    let size = model.node(forPath: "/documentation/testkit/widget/size")
    #expect(size?.ancestors.map(\.title) == ["TestKit", "Widget"])
  }
  
  @Test func restrictsToRequestedRoots() throws {
    let fixture = try TestArchive()
    defer { fixture.remove() }
    let archive = try DocumentationArchive(url: fixture.url)
    let model = try DocumentModel(archive: archive, rootPaths: ["/documentation/testkit/widget"])
    #expect(model.orderedNodes.map(\.title) == ["Widget", "size"])
    #expect(throws: DoccToPdfError.self) {
      try DocumentModel(archive: archive, rootPaths: ["/documentation/missing"])
    }
  }
  
  @Test func rejectsDirectoriesWithoutRenderJSON() {
    #expect(throws: DoccToPdfError.self) {
      try DocumentationArchive(url: FileManager.default.temporaryDirectory)
    }
  }
  
  @Test func normalizesPaths() {
    #expect(DocumentationArchive.normalize("doc://Bundle/documentation/Kit/Foo#bar")
      == "/documentation/kit/foo")
    #expect(DocumentationArchive.normalize("documentation/kit/") == "/documentation/kit")
  }
}

@Suite struct HTMLRendererTests {
  private func render(_ configure: (inout RenderOptions) -> Void = { _ in }) throws -> String {
    let fixture = try TestArchive()
    defer { fixture.remove() }
    var options = RenderOptions()
    configure(&options)
    let model = try DocumentModel(archive: DocumentationArchive(url: fixture.url))
    return HTMLRenderer(model: model, options: options).render()
  }
  
  @Test func rendersInternalAndExternalLinks() throws {
    let html = try render()
    #expect(html.contains("<a href=\"#t3\"><code>Widget</code></a>"))
    #expect(html.contains("<a href=\"#t2\">Getting Started</a>"))
    #expect(html.contains("<a href=\"https://swift.org\">Swift.org</a>"))
      // Type identifiers in declarations link to their pages.
    #expect(html.contains("<a class=\"tok-type\" href=\"#t3\">Widget</a>"))
  }
  
  @Test func escapesTextAndRendersBlocks() throws {
    let html = try render()
    #expect(html.contains("A kit for &lt;testing&gt;."))
    #expect(html.contains(
      "<div class=\"aside aside-warning\"><p class=\"aside-label\">Warning</p>"))
    #expect(html.contains("<h2 id=\"t1-overview\" data-keep-with-next>Overview</h2>"))
    #expect(html.contains("<span class=\"tok-comment\">// one</span>"))
  }
  
  @Test func buildsTableOfContentsAndCover() throws {
    let html = try render()
    #expect(html.contains("class=\"cover\""))
    #expect(html.contains("data-target=\"t1-Essentials\""))
      // With the default depth of 1, members of types are not listed.
    #expect(!html.contains("data-target=\"t4\""))
    let deeper = try render { $0.tocDepth = 2; $0.includeCover = false }
    #expect(deeper.contains("data-target=\"t4\""))
    #expect(!deeper.contains("class=\"cover\""))
    let none = try render { $0.tocDepth = nil }
    #expect(!none.contains("class=\"toc"))
  }
  
  @Test func pageBreakModes() throws {
    let auto = try render()
    #expect(auto.contains("<article class=\"topic flow leaf\" id=\"t4\""))
    let all = try render { $0.pageBreaks = .all }
    #expect(all.contains("<article class=\"topic page-break leaf\" id=\"t4\""))
    let none = try render { $0.pageBreaks = .none }
    #expect(none.contains("<article class=\"topic flow\" id=\"t2\""))
  }
  
  @Test func keepsAllTopicGroupsInTheOwningPageByDefault() throws {
    let html = try render()
    #expect(html.contains("<h2 id=\"t1-Topics\" data-keep-with-next>Topics</h2>"))
    #expect(html.contains("<h3 id=\"t1-Essentials\" data-keep-with-next>Essentials</h3>"))
    #expect(!html.contains("<section class=\"group-section"))
    // The pages follow the root page without topic group sections in between.
    let root = try #require(html.range(of: "id=\"t1\"")).lowerBound
    let topics = try #require(html.range(of: "id=\"t1-Topics\"")).lowerBound
    let guide = try #require(html.range(of: "id=\"t2\"")).lowerBound
    #expect(root < topics && topics < guide)
  }
  
  @Test func placesTopicGroupsBeforeTheirPagesWhenMonotonic() throws {
    let html = try render { $0.monotonic = true }
    func position(_ marker: String) throws -> String.Index {
      try #require(html.range(of: marker)).lowerBound
    }
    // The root's topic group follows the root page and precedes the pages it contains.
    let root = try position("<article class=\"topic page-break\" id=\"t1\"")
    let group = try position("<section class=\"group-section page-break\" id=\"t1-Essentials\"")
    let guide = try position("id=\"t2\"")
    let widget = try position("id=\"t3\"")
    #expect(root < group && group < guide && guide < widget)
    // The members of a type are introduced by a group that flows with them.
    let members = try position(
      "<section class=\"group-section flow\" id=\"t3-Instance_Properties\"")
    let size = try position("id=\"t4\"")
    #expect(widget < members && members < size)
    // The pages no longer carry a combined "Topics" block.
    #expect(!html.contains(">Topics</h2>"))
    #expect(html.contains("<h2 class=\"group-title\">Essentials</h2>"))
    #expect(html.contains("data-running-title=\"Essentials\""))
    // The running header of a flowing group names the type it belongs to.
    #expect(html.contains("id=\"t3-Instance_Properties\" data-running-title=\"Widget\""))
  }
  
  @Test func monotonicTopicGroupsFollowThePageBreakMode() throws {
    let all = try render { $0.monotonic = true; $0.pageBreaks = .all }
    #expect(all.contains(
      "<section class=\"group-section page-break\" id=\"t3-Instance_Properties\""))
    let none = try render { $0.monotonic = true; $0.pageBreaks = .none }
    #expect(none.contains("<section class=\"group-section flow\" id=\"t1-Essentials\""))
  }
  
  @Test func breakableTitles() {
    #expect(HTMLRenderer.breakableTitle("Foo.barBaz") == "Foo.<wbr>bar<wbr>Baz")
    #expect(HTMLRenderer.breakableTitle("a<b") == "a&lt;b")
    #expect(HTMLRenderer.elementID("t3", "Topics & More") == "t3-Topics___More")
  }
}

@Suite struct StatisticsTests {
  @Test func countsFixturePagesByCategory() throws {
    let fixture = try TestArchive()
    defer { fixture.remove() }
    let model = try DocumentModel(archive: DocumentationArchive(url: fixture.url))
    let statistics = DocumentStatistics(model: model)
    #expect(statistics.total == 5)
    #expect(statistics.entries(in: .pages) == [
      .init(group: .pages, label: "Articles", count: 2),
    ])
    #expect(statistics.count(of: "Modules") == 1)
    #expect(statistics.count(of: "Structures") == 1)
    #expect(statistics.count(of: "Properties") == 1)
    #expect(statistics.count(of: "Classes") == 0)
    #expect(statistics.entries(in: .other).isEmpty)
  }

  @Test func classifiesSymbolKindsAndFallsBack() {
    func symbol(_ kind: JSON?, heading: JSON? = nil) -> JSON {
      var metadata: [String: JSON] = [:]
      metadata["symbolKind"] = kind
      metadata["roleHeading"] = heading
      return ["kind": "symbol", "metadata": JSON.object(metadata)]
    }
    let collection: JSON = ["kind": "article", "metadata": ["role": "collectionGroup"]]
    let statistics = DocumentStatistics(pages: [
      symbol("struct"), symbol("class"), symbol("class"), symbol("enum"), symbol("protocol"),
      symbol("method", heading: "Instance Method"), symbol("method", heading: "Type Method"),
      symbol("func"), symbol("property"), symbol("var"), symbol("init"), symbol("case"),
      symbol("op"), symbol("subscript"), symbol("typealias"),
      symbol("deinit", heading: "Deinitializer"), symbol(nil),
      collection, collection, ["kind": "article", "metadata": ["role": "article"]],
    ])
    #expect(statistics.total == 20)
    #expect(statistics.count(of: "Classes") == 2)
    #expect(statistics.count(of: "Methods") == 3)
    #expect(statistics.count(of: "Properties") == 2)
    #expect(statistics.count(of: "Type aliases") == 1)
    #expect(statistics.count(of: "API collections") == 2)
    #expect(statistics.count(of: "Articles") == 1)
    #expect(statistics.count(of: "Deinitializers") == 1)
    #expect(statistics.count(of: "Other symbols") == 1)
    // Pages come first, then types, then members, then everything else.
    #expect(statistics.entries.map(\.group)
      == [.pages, .pages, .types, .types, .types, .types, .types, .members, .members, .members,
          .members, .members, .members, .other, .other])
  }
}

@Suite struct SyntaxHighlighterTests {
  @Test func highlightsSwift() throws {
    let highlighter = try #require(SyntaxHighlighter.forLanguage("swift"))
    let lines = highlighter.highlight(lines: [
      "@MainActor func f() -> Int { return 0x1F } // done",
      "let s = \"a \\\"b\\\"\" /* start",
      "end */ let t = \"\"\"",
      "text",
      "\"\"\"",
    ])
    #expect(lines[0].contains("<span class=\"tok-attribute\">@MainActor</span>"))
    #expect(lines[0].contains("<span class=\"tok-keyword\">func</span>"))
    #expect(lines[0].contains("<span class=\"tok-type\">Int</span>"))
    #expect(lines[0].contains("<span class=\"tok-number\">0x1F</span>"))
    #expect(lines[0].hasSuffix("<span class=\"tok-comment\">// done</span>"))
    #expect(lines[1].contains("<span class=\"tok-string\">&quot;a \\&quot;b\\&quot;&quot;</span>"))
    #expect(lines[1].hasSuffix("<span class=\"tok-comment\">/* start</span>"))
    #expect(lines[2].hasPrefix("<span class=\"tok-comment\">end */</span>"))
    #expect(lines[3] == "<span class=\"tok-string\">text</span>")
    #expect(lines[4] == "<span class=\"tok-string\">&quot;&quot;&quot;</span>")
  }
  
  @Test func leavesUnknownLanguagesAlone() {
    #expect(SyntaxHighlighter.forLanguage("brainfuck") == nil)
    #expect(SyntaxHighlighter.forLanguage(nil) == nil)
  }
}

@Suite struct OptionsTests {
  @Test func parsesPaperSizes() {
    #expect(PaperSize(name: "A4") == .a4)
    #expect(PaperSize(name: "500x700") == PaperSize(width: 500, height: 700))
    #expect(PaperSize(name: "10x10") == nil)
    #expect(PaperSize(name: "b5") == nil)
  }
}

@Suite(.serialized) @MainActor struct PDFGenerationTests {
  @Test func generatesNavigablePDF() async throws {
    let fixture = try TestArchive()
    defer { fixture.remove() }
    let output = fixture.url.deletingLastPathComponent().appendingPathComponent("TestKit.pdf")
    var options = RenderOptions()
    options.paper = .letter
    // The ordering checks below rely on topic groups being placed before their pages.
    options.monotonic = true
    let summary = try await PDFGenerator(options: options)
      .generate(archiveURL: fixture.url, outputURL: output)
    
    let document = try #require(PDFDocument(url: output))
    #expect(document.pageCount == summary.pageCount)
    #expect(summary.pageCount >= 5)
    #expect(summary.topicCount == 5)
    #expect(summary.statistics.total == 5)
    #expect(summary.internalLinkCount > 5)
    #expect(summary.externalLinkCount == 1)
    #expect(summary.linkCount == summary.internalLinkCount + summary.externalLinkCount)
    // Contents, TestKit, Essentials, Getting Started, Widget, Instance Properties, size, Orphan.
    #expect(summary.outlineItemCount == 8)
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    #expect(summary.fileSize == (attributes[.size] as? Int))
    let report = summary.report()
    #expect(report.contains("PDF pages"))
    #expect(report.contains("Structures"))
    let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
    #expect(title == "TestKit")
    let page = try #require(document.page(at: 0))
    #expect(page.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
    
    // Outline: Contents, TestKit (with its group and children), Orphan.
    let outline = try #require(document.outlineRoot)
    let labels = (0..<outline.numberOfChildren).compactMap { outline.child(at: $0)?.label }
    #expect(labels == ["Contents", "TestKit", "Orphan"])
    let essentials = try #require(outline.child(at: 1)?.child(at: 0))
    #expect(essentials.label == "Essentials")
    let children = (0..<essentials.numberOfChildren).compactMap { essentials.child(at: $0)?.label }
    #expect(children == ["Getting Started", "Widget"])
    
    // The pages follow the structure of the outline and the table of contents: the root
    // page, then its group, then the group's pages.
    func pageIndex(_ item: PDFOutline?) throws -> Int {
      document.index(for: try #require(item?.destination?.page))
    }
    let testKit = try #require(outline.child(at: 1))
    let rootPage = try pageIndex(testKit)
    let essentialsPage = try pageIndex(essentials)
    let guidePage = try pageIndex(essentials.child(at: 0))
    let widgetPage = try pageIndex(essentials.child(at: 1))
    #expect(rootPage < essentialsPage && essentialsPage < guidePage && guidePage < widgetPage)
    #expect(try #require(essentials.destination?.page).string?.contains("Essentials") == true)
    let properties = try #require(essentials.child(at: 1)?.child(at: 0))
    #expect(properties.label == "Instance Properties")
    let propertiesPage = try pageIndex(properties)
    let sizePage = try pageIndex(properties.child(at: 0))
    #expect(widgetPage <= propertiesPage && propertiesPage <= sizePage)
    
    // Each outline destination lands on a page showing that title.
    for index in 0..<outline.numberOfChildren {
      let item = try #require(outline.child(at: index))
      let target = try #require(item.destination?.page)
      #expect(target.string?.contains(item.label ?? "?") == true)
    }
    
    // Internal links resolve to pages; the external link keeps its URL.
    var internalLinks = 0, externalLinks: [URL] = []
    for index in 0..<document.pageCount {
      let annotations = document.page(at: index)?.annotations ?? []
      for annotation in annotations where annotation.type == "Link" {
        let goTo = annotation.action as? PDFActionGoTo
        if let destination = annotation.destination ?? goTo?.destination {
          #expect(destination.page != nil)
          internalLinks += 1
        } else if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
          externalLinks.append(url)
        }
      }
    }
    #expect(internalLinks > 5)
    #expect(externalLinks == [URL(string: "https://swift.org")!])
    
    // Every page's text is unique to it: no hidden duplicates of other pages.
    let hits = document.findString("Paragraph 40 with", withOptions: [])
    #expect(hits.count == 1)
  }
  
  @Test func listsTopicGroupsInTheOwningPageByDefault() async throws {
    let fixture = try TestArchive()
    defer { fixture.remove() }
    let output = fixture.url.deletingLastPathComponent().appendingPathComponent("TestKit.pdf")
    var options = RenderOptions()
    options.paper = .letter
    try await PDFGenerator(options: options).generate(archiveURL: fixture.url, outputURL: output)
    
    let document = try #require(PDFDocument(url: output))
    let outline = try #require(document.outlineRoot)
    let testKit = try #require(outline.child(at: 1))
    let essentials = try #require(testKit.child(at: 0))
    #expect(essentials.label == "Essentials")
    func pageIndex(_ item: PDFOutline?) throws -> Int {
      document.index(for: try #require(item?.destination?.page))
    }
    // The group's entry points into the root page's "Topics" section, before the pages.
    let rootPage = try pageIndex(testKit)
    #expect(try pageIndex(essentials) == rootPage)
    #expect(rootPage < (try pageIndex(essentials.child(at: 0))))
  }
}
