//
//  Docc2Pdf.swift
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
import ArgumentParser
import DoccToPdfCore

@main
struct Docc2Pdf: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "docc2pdf",
    abstract: "Convert a DocC documentation archive (.doccarchive) into a browsable PDF file.",
    discussion: """
        The PDF contains a cover page, a table of contents with page numbers, an \
        outline (bookmarks) that mirrors the documentation's curation, and clickable \
        links between pages. Symbol references that point outside the archive are \
        rendered as plain text; web links stay clickable.
        """,
    version: "1.0.0"
  )
  
  @Argument(help: "Path to the .doccarchive directory.", completion: .directory)
  var archive: String
  
  @Option(name: .shortAndLong,
          help: "Output PDF path. (default: <archive name>.pdf in the current directory)")
  var output: String?
  
  @Option(help: "Paper size: letter, legal, a4, a5, or WIDTHxHEIGHT in points. (default: based on your region)")
  var paper: String?
  
  @Option(help: "Page margin in points.")
  var margin: Double = 54
  
  @Option(help: "Body text size in points.")
  var fontSize: Double = 10
  
  @Option(help: "When documentation pages start a new PDF page: auto, all, or none.")
  var pageBreaks: PageBreakMode = .auto
  
  @Option(help: "Depth of pages listed in the table of contents (0 = top-level pages only).")
  var tocDepth: Int = 1
  
  @Flag(help: "Omit the table of contents.")
  var noToc = false
  
  @Flag(help: "Omit the cover page.")
  var noCover = false
  
  @Option(help: "Document title. (default: the archive's display name)")
  var title: String?
  
  @Option(name: .customLong("root"),
          help: ArgumentHelp(
            "Only include this documentation path and the pages it curates, e.g. /documentation/mykit/mytype. Repeatable.",
            valueName: "path"))
  var roots: [String] = []
  
  @Option(help: ArgumentHelp(
            "Also write the intermediate HTML to this path (useful for debugging styles).",
            valueName: "path"))
  var saveHtml: String?
  
  @Flag(name: .shortAndLong, help: "Print progress information.")
  var verbose = false
  
  func validate() throws {
    if let paper, PaperSize(name: paper) == nil {
      throw ValidationError("Unknown paper size '\(paper)'. " +
                            "Use letter, legal, a4, a5, or WIDTHxHEIGHT in points.")
    }
    let size = paper.flatMap(PaperSize.init(name:)) ?? .localeDefault
    guard margin >= 0, margin * 2 < min(size.width, size.height) - 144 else {
      throw ValidationError("The margin leaves too little room for content.")
    }
    guard (5...30).contains(fontSize) else {
      throw ValidationError("--font-size must be between 5 and 30.")
    }
    guard tocDepth >= 0 else {
      throw ValidationError("--toc-depth must not be negative.")
    }
  }
  
  func run() async throws {
    let archiveURL = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: archiveURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ValidationError("No archive directory at \(archiveURL.path).")
    }
    let outputURL = URL(fileURLWithPath: (output.map { ($0 as NSString).expandingTildeInPath })
                        ?? archiveURL.deletingPathExtension().lastPathComponent + ".pdf").standardizedFileURL
    
    var options = RenderOptions()
    options.paper = paper.flatMap(PaperSize.init(name:)) ?? .localeDefault
    options.margin = margin
    options.fontSize = fontSize
    options.pageBreaks = pageBreaks
    options.tocDepth = noToc ? nil : tocDepth
    options.includeCover = !noCover
    options.title = title
    options.rootPaths = roots
    let verbose = self.verbose
    let started = Date()
    let generator = await PDFGenerator(options: options) { message in
      if verbose {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
      }
    }
    let summary = try await generator.generate(
      archiveURL: archiveURL,
      outputURL: outputURL,
      htmlOutputURL: saveHtml.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
      })
    let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
    print("Wrote \(outputURL.path) (\(summary.pageCount) pages, \(summary.topicCount) topics, \(summary.linkCount) links) in \(seconds)s")
  }
}

extension PageBreakMode: ExpressibleByArgument {}
