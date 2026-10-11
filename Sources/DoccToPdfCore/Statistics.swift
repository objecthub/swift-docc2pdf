//
//  Statistics.swift
//  Docc2Pdf
//
//  Created by Matthias Zenger on 11/10/2026.
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

/// The number of documentation pages in a `DocumentModel`, broken down by what the pages
/// document: articles and collections, types, and members such as methods and properties.
public struct DocumentStatistics: Sendable, Equatable {
  /// Coarse classification of a category; used to order the report.
  public enum Group: Sendable, CaseIterable {
    /// Articles, collections, and tutorials.
    case pages
    /// Modules, structures, classes, enumerations, protocols, and the like.
    case types
    /// Initializers, methods, properties, enumeration cases, and the like.
    case members
    /// Pages that match no other category.
    case other
  }

  public struct Entry: Sendable, Equatable {
    public let group: Group
    public let label: String
    public let count: Int
  }

  /// Categories with at least one page: articles first, then types, then members.
  public let entries: [Entry]

  /// The total number of pages.
  public var total: Int {
    entries.reduce(0) { $0 + $1.count }
  }

  public init(model: DocumentModel) {
    self.init(pages: model.orderedNodes.map(\.page))
  }

  init(pages: [JSON]) {
    var counts: [Category: Int] = [:]
    var others: [String: Int] = [:]
    for page in pages {
      if let category = Self.category(of: page) {
        counts[category, default: 0] += 1
      } else {
        others[Self.otherLabel(of: page), default: 0] += 1
      }
    }
    var entries = Category.allCases.compactMap { category in
      counts[category].map { Entry(group: category.group, label: category.label, count: $0) }
    }
    entries += others.sorted { $0.key < $1.key }.map {
      Entry(group: .other, label: $0.key, count: $0.value)
    }
    self.entries = entries
  }

  /// The entries of one group, in report order.
  public func entries(in group: Group) -> [Entry] {
    entries.filter { $0.group == group }
  }

  /// The number of pages in the category with the given label (0 if there are none).
  public func count(of label: String) -> Int {
    entries.first { $0.label == label }?.count ?? 0
  }

  // MARK: - Classification

  /// The known page categories, in report order.
  private enum Category: CaseIterable {
    case article, apiCollection, tutorial, tutorialOverview
    case module, structure, classType, enumeration, protocolType, actor, typeAlias
    case associatedType, macro, extensionType
    case initializer, method, property, subscriptMember, enumerationCase, operatorMember

    var group: Group {
      switch self {
        case .article, .apiCollection, .tutorial, .tutorialOverview:
          return .pages
        case .module, .structure, .classType, .enumeration, .protocolType, .actor, .typeAlias,
             .associatedType, .macro, .extensionType:
          return .types
        case .initializer, .method, .property, .subscriptMember, .enumerationCase,
             .operatorMember:
          return .members
      }
    }

    var label: String {
      switch self {
        case .article: return "Articles"
        case .apiCollection: return "API collections"
        case .tutorial: return "Tutorials"
        case .tutorialOverview: return "Tutorial overviews"
        case .module: return "Modules"
        case .structure: return "Structures"
        case .classType: return "Classes"
        case .enumeration: return "Enumerations"
        case .protocolType: return "Protocols"
        case .actor: return "Actors"
        case .typeAlias: return "Type aliases"
        case .associatedType: return "Associated types"
        case .macro: return "Macros"
        case .extensionType: return "Extensions"
        case .initializer: return "Initializers"
        case .method: return "Methods"
        case .property: return "Properties"
        case .subscriptMember: return "Subscripts"
        case .enumerationCase: return "Enumeration cases"
        case .operatorMember: return "Operators"
      }
    }
  }

  /// Symbols are classified by their language-independent `symbolKind`, everything else by
  /// the page's `kind` and `role`. Instance and type members are counted together.
  private static func category(of page: JSON) -> Category? {
    let metadata = page["metadata"]
    if let symbolKind = metadata?["symbolKind"]?.stringValue {
      switch symbolKind.lowercased() {
        case "module": return .module
        case "struct": return .structure
        case "class": return .classType
        case "enum": return .enumeration
        case "protocol": return .protocolType
        case "actor": return .actor
        case "typealias": return .typeAlias
        case "associatedtype": return .associatedType
        case "macro": return .macro
        case "extension": return .extensionType
        case "init": return .initializer
        case "method", "func", "typemethod": return .method
        case "property", "var", "typeproperty", "ivar": return .property
        case "subscript", "typesubscript": return .subscriptMember
        case "case": return .enumerationCase
        case "op", "operator": return .operatorMember
        default: return nil
      }
    }
    switch (page["kind"]?.stringValue, metadata?["role"]?.stringValue) {
      case (_, "collectionGroup"?): return .apiCollection
      case ("article"?, _): return .article
      case ("tutorial"?, _), ("project"?, _): return .tutorial
      case ("overview"?, _): return .tutorialOverview
      default: return nil
    }
  }

  /// The label for a page that fits no known category: its role heading in plural form.
  private static func otherLabel(of page: JSON) -> String {
    if let heading = page["metadata"]?["roleHeading"]?.stringValue, !heading.isEmpty {
      return heading.hasSuffix("s") ? heading : heading + "s"
    }
    return page["kind"]?.stringValue == "symbol" ? "Other symbols" : "Other pages"
  }
}

extension PDFGenerator.Summary {
  /// A human-readable, multi-line report of the generated PDF and its pages.
  public func report() -> String {
    typealias Row = (indent: Int, label: String, value: String, note: String)
    var rows: [Row] = [
      (0, "PDF pages", pageCount.formatted(), ""),
      (0, "File size", ByteCountFormatter.string(fromByteCount: Int64(fileSize),
                                                 countStyle: .file), ""),
      (0, "Links", linkCount.formatted(),
       "(\(internalLinkCount.formatted()) internal, \(externalLinkCount.formatted()) external)"),
      (0, "Outline items", outlineItemCount.formatted(), ""),
      (0, "Documentation pages", statistics.total.formatted(), ""),
    ]
    for group in DocumentStatistics.Group.allCases {
      for entry in statistics.entries(in: group) {
        rows.append((1, entry.label, entry.count.formatted(), ""))
      }
    }
    let labelWidth = rows.map { $0.indent * 2 + $0.label.count }.max() ?? 0
    let valueWidth = rows.map(\.value.count).max() ?? 0
    return rows.map { row in
      let label = String(repeating: " ", count: row.indent * 2) + row.label
      let value = String(repeating: " ", count: valueWidth - row.value.count) + row.value
      let line = "  " + label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        + "  " + value
      return row.note.isEmpty ? line : line + "  " + row.note
    }.joined(separator: "\n")
  }
}
