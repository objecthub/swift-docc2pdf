//
//  Options.swift
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

public enum PageBreakMode: String, CaseIterable, Sendable {
    /// Articles, tutorials, and pages that curate other pages start on a new page;
    /// leaf symbols (properties, methods, cases, …) flow continuously.
    case auto
    /// Every documentation page starts on a new PDF page.
    case all
    /// Pages flow continuously; only the front matter forces page breaks.
    case none
}

public struct PaperSize: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let letter = PaperSize(width: 612, height: 792)
    public static let legal = PaperSize(width: 612, height: 1008)
    public static let a4 = PaperSize(width: 595.28, height: 841.89)
    public static let a5 = PaperSize(width: 419.53, height: 595.28)

    /// Letter in regions using US customary units, A4 everywhere else.
    public static var localeDefault: PaperSize {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }

    /// Parses `letter`, `legal`, `a4`, `a5`, or a custom `WIDTHxHEIGHT` size in points.
    public init?(name: String) {
        switch name.lowercased() {
        case "letter": self = .letter
        case "legal": self = .legal
        case "a4": self = .a4
        case "a5": self = .a5
        default:
            let parts = name.lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts[0] >= 144, parts[1] >= 144 else { return nil }
            self.init(width: parts[0], height: parts[1])
        }
    }
}

public struct RenderOptions: Sendable {
    public var paper: PaperSize = .localeDefault
    /// Page margin in points; the running header and footer sit inside it.
    public var margin: Double = 54
    /// Body text size in points.
    public var fontSize: Double = 10
    public var pageBreaks: PageBreakMode = .auto
    /// Maximum page depth listed in the table of contents (0 = top-level pages only),
    /// or `nil` to omit the table of contents.
    public var tocDepth: Int? = 1
    public var includeCover = true
    public var title: String?
    /// Documentation paths to restrict the output to (with their curated descendants).
    public var rootPaths: [String] = []
    public var generationDate = Date()

    public init() {}

    public var contentWidth: Double { paper.width - 2 * margin }
    public var contentHeight: Double { paper.height - 2 * margin }
}
