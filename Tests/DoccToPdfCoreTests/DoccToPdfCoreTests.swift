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
        #expect(model.orderedNodes.map(\.title) == ["TestKit", "Getting Started", "Widget", "size", "Orphan"])
        #expect(model.orderedNodes.map(\.depth) == [0, 1, 1, 2, 0])
        #expect(model.roots.map(\.title) == ["TestKit", "Orphan"])
        let root = model.roots[0]
        #expect(root.groups.map(\.title) == ["Essentials"])
        #expect(root.groups[0].anchorID == "t1-Essentials")
        #expect(model.node(forPath: "/documentation/testkit/widget/size")?.ancestors.map(\.title) == ["TestKit", "Widget"])
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
        #expect(DocumentationArchive.normalize("doc://Bundle/documentation/Kit/Foo#bar") == "/documentation/kit/foo")
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
        #expect(html.contains("<div class=\"aside aside-warning\"><p class=\"aside-label\">Warning</p>"))
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

    @Test func breakableTitles() {
        #expect(HTMLRenderer.breakableTitle("Foo.barBaz") == "Foo.<wbr>bar<wbr>Baz")
        #expect(HTMLRenderer.breakableTitle("a<b") == "a&lt;b")
        #expect(HTMLRenderer.elementID("t3", "Topics & More") == "t3-Topics___More")
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
        let summary = try await PDFGenerator(options: options).generate(archiveURL: fixture.url, outputURL: output)

        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == summary.pageCount)
        #expect(summary.pageCount >= 5)
        #expect(summary.topicCount == 5)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "TestKit")
        let page = try #require(document.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))

        // Outline: Contents, TestKit (with its group and children), Orphan.
        let outline = try #require(document.outlineRoot)
        let labels = (0..<outline.numberOfChildren).compactMap { outline.child(at: $0)?.label }
        #expect(labels == ["Contents", "TestKit", "Orphan"])
        let essentials = try #require(outline.child(at: 1)?.child(at: 0))
        #expect(essentials.label == "Essentials")
        #expect((0..<essentials.numberOfChildren).compactMap { essentials.child(at: $0)?.label } == ["Getting Started", "Widget"])

        // Each outline destination lands on a page showing that title.
        for index in 0..<outline.numberOfChildren {
            let item = try #require(outline.child(at: index))
            let target = try #require(item.destination?.page)
            #expect(target.string?.contains(item.label ?? "?") == true)
        }

        // Internal links resolve to pages; the external link keeps its URL.
        var internalLinks = 0, externalLinks: [URL] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination {
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
}
