//
//  TestArchive.swift
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

/// Builds a minimal `.doccarchive` on disk with hand-written render JSON.
struct TestArchive {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("docc2pdf-tests-\(UUID().uuidString)/TestKit.doccarchive", isDirectory: true)
        try write("metadata.json", ["bundleDisplayName": "TestKit", "bundleID": "com.example.TestKit"])
        try write("index/index.json", [
            "interfaceLanguages": ["swift": [["path": "/documentation/testkit", "title": "TestKit", "type": "module"]]],
        ])
        try page("/documentation/testkit", kind: "symbol", role: "collection", title: "TestKit",
                 abstract: "A kit for <testing>.",
                 content: [
                     ["type": "heading", "level": 2, "text": "Overview", "anchor": "overview"],
                     ["type": "paragraph", "inlineContent": [
                         ["type": "text", "text": "Use "],
                         ["type": "reference", "identifier": "doc://TestKit/documentation/TestKit/Widget", "isActive": true],
                         ["type": "text", "text": " or read "],
                         ["type": "reference", "identifier": "doc://TestKit/documentation/TestKit/Guide", "isActive": true],
                         ["type": "text", "text": ". See "],
                         ["type": "reference", "identifier": "https://swift.org", "isActive": true],
                         ["type": "text", "text": "."],
                     ]],
                     ["type": "aside", "style": "warning", "content": [
                         ["type": "paragraph", "inlineContent": [["type": "text", "text": "Careful."]]],
                     ]],
                     ["type": "codeListing", "syntax": "swift", "code": ["let x = 1 // one", "print(\"hi\")"]],
                 ],
                 topics: [
                     ["title": "Essentials", "anchor": "Essentials", "identifiers": [
                         "doc://TestKit/documentation/TestKit/Guide",
                         "doc://TestKit/documentation/TestKit/Widget",
                     ]],
                 ])
        try page("/documentation/testkit/guide", kind: "article", role: "article", title: "Getting Started",
                 abstract: "Learn the basics.", content: longContent(paragraphs: 80))
        try page("/documentation/testkit/widget", kind: "symbol", role: "symbol", title: "Widget",
                 abstract: "A widget.", content: [],
                 declaration: [["kind": "keyword", "text": "struct"], ["kind": "text", "text": " "],
                               ["kind": "identifier", "text": "Widget"]],
                 topics: [
                     ["title": "Instance Properties", "identifiers": ["doc://TestKit/documentation/TestKit/Widget/size"]],
                 ])
        try page("/documentation/testkit/widget/size", kind: "symbol", role: "symbol", title: "size",
                 abstract: "The size.", content: [],
                 declaration: [["kind": "keyword", "text": "var"], ["kind": "text", "text": " "],
                               ["kind": "identifier", "text": "size"], ["kind": "text", "text": ": "],
                               ["kind": "typeIdentifier", "text": "Widget",
                                "identifier": "doc://TestKit/documentation/TestKit/Widget"]])
        // Not curated anywhere; must still end up in the book.
        try page("/documentation/testkit/orphan", kind: "article", role: "article", title: "Orphan",
                 abstract: "Uncurated.", content: [])
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func longContent(paragraphs: Int) -> [[String: Any]] {
        (1...paragraphs).map { index in
            ["type": "paragraph", "inlineContent": [["type": "text", "text":
                "Paragraph \(index) with enough words to wrap onto several lines of text in the rendered page, "
                + "so the document needs more than one page."]]]
        }
    }

    private static var references: [String: Any] { [
        "doc://TestKit/documentation/TestKit": [
            "type": "topic", "title": "TestKit", "url": "/documentation/testkit", "kind": "symbol", "role": "collection",
        ],
        "doc://TestKit/documentation/TestKit/Guide": [
            "type": "topic", "title": "Getting Started", "url": "/documentation/testkit/guide", "kind": "article",
            "abstract": [["type": "text", "text": "Learn the basics."]],
        ],
        "doc://TestKit/documentation/TestKit/Widget": [
            "type": "topic", "title": "Widget", "url": "/documentation/testkit/widget", "kind": "symbol",
            "fragments": [["kind": "keyword", "text": "struct"], ["kind": "text", "text": " "],
                          ["kind": "identifier", "text": "Widget"]],
            "abstract": [["type": "text", "text": "A widget."]],
        ],
        "doc://TestKit/documentation/TestKit/Widget/size": [
            "type": "topic", "title": "size", "url": "/documentation/testkit/widget/size", "kind": "symbol",
        ],
        "https://swift.org": [
            "type": "link", "title": "Swift.org", "url": "https://swift.org",
            "titleInlineContent": [["type": "text", "text": "Swift.org"]],
        ],
    ] }

    private func page(_ path: String, kind: String, role: String, title: String, abstract: String,
                      content: [[String: Any]], declaration: [[String: Any]]? = nil,
                      topics: [[String: Any]] = []) throws {
        var sections: [[String: Any]] = []
        if let declaration {
            sections.append(["kind": "declarations", "declarations": [["tokens": declaration, "languages": ["swift"]]]])
        }
        if !content.isEmpty { sections.append(["kind": "content", "content": content]) }
        let json: [String: Any] = [
            "kind": kind,
            "identifier": ["url": "doc://TestKit" + path, "interfaceLanguage": "swift"],
            "metadata": ["title": title, "role": role],
            "abstract": [["type": "text", "text": abstract]],
            "primaryContentSections": sections,
            "topicSections": topics,
            "sections": [],
            "references": Self.references,
        ]
        try write("data\(path).json", json)
    }

    private func write(_ relativePath: String, _ object: Any) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
}
