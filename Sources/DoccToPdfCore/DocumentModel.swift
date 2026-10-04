//
//  DocumentModel.swift
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

/// A documentation page placed in the book.
public final class TopicNode {
  public let path: String
  public let page: JSON
  /// HTML id of the page's section in the generated document.
  public let anchorID: String
  public let depth: Int
  public private(set) weak var parent: TopicNode?
  public internal(set) var groups: [TopicGroup] = []
  
  init(path: String, page: JSON, anchorID: String, depth: Int, parent: TopicNode?) {
    self.path = path
    self.page = page
    self.anchorID = anchorID
    self.depth = depth
    self.parent = parent
  }
  
  public var title: String {
    page["metadata"]?["title"]?.stringValue ?? path.split(separator: "/").last.map(String.init) ??
    path
  }
  
  public var kind: String? { page["kind"]?.stringValue }
  public var role: String? { page["metadata"]?["role"]?.stringValue }
  
  public var references: JSON { page["references"] ?? .object([:]) }
  
  /// Ancestors from the root down to the direct parent.
  public var ancestors: [TopicNode] {
    var result: [TopicNode] = []
    var current = parent
    while let node = current {
      result.insert(node, at: 0)
      current = node.parent
    }
    return result
  }
  
  /// Whether the page curates other pages (a module, a type, a collection, a tutorial overview).
  public var hasCuratedChildren: Bool {
    !page["topicSections"].items.isEmpty || !page["sections"].items.filter {
      $0["kind"]?.stringValue == "volume"
    }.isEmpty
  }
}

/// A titled group of child pages, such as a "Topics" section of a type.
public struct TopicGroup {
  public let title: String
  public let anchorID: String
  /// Children placed in the book under this group (pages curated in several
  /// places appear only under the first one).
  public internal(set) var topics: [TopicNode]
}

/// The book structure: pages in reading order, following the documentation's curation.
public final class DocumentModel {
  public let archive: DocumentationArchive
  public private(set) var roots: [TopicNode] = []
  public private(set) var orderedNodes: [TopicNode] = []
  private var nodesByPath: [String: TopicNode] = [:]
  
  /// - Parameters:
  ///   - rootPaths: Documentation paths to start from. When empty, the archive's
  ///     top-level pages are used and pages missing from the curation tree are appended.
  public init(archive: DocumentationArchive, rootPaths: [String] = []) throws {
    self.archive = archive
    let requested = rootPaths.map(DocumentationArchive.normalize)
    for path in requested where !archive.contains(path: path) {
      throw DoccToPdfError.pageNotFound(path)
    }
    for path in requested.isEmpty ? archive.rootPaths() : requested {
      if let node = try visit(path: path, parent: nil, depth: 0) {
        roots.append(node)
      }
    }
    if requested.isEmpty {
      // Pages not reachable from curation (rare, but possible with custom
      // curation) are appended so nothing in the archive is lost.
      for path in archive.allPaths where nodesByPath[path] == nil {
        if let node = try visit(path: path, parent: nil, depth: 0) {
          roots.append(node)
        }
      }
    }
  }
  
  public func node(forPath path: String) -> TopicNode? {
    nodesByPath[DocumentationArchive.normalize(path)]
  }
  
  private func visit(path: String, parent: TopicNode?, depth: Int) throws -> TopicNode? {
    let key = DocumentationArchive.normalize(path)
    guard nodesByPath[key] == nil, archive.contains(path: key) else { return nil }
    let page = try archive.page(at: key)
    let node = TopicNode(path: key,
                         page: page,
                         anchorID: "t\(orderedNodes.count + 1)", depth: depth, parent: parent)
    nodesByPath[key] = node
    orderedNodes.append(node)
    for (title, anchor, identifiers) in Self.childGroups(of: page) {
      var group = TopicGroup(title: title, anchorID: HTMLRenderer.elementID(node.anchorID, anchor), topics: [])
      for identifier in identifiers {
        guard let url = page["references"]?[identifier]?["url"]?.stringValue,
              url.hasPrefix("/") else { continue }
        if let child = try visit(path: url, parent: node, depth: depth + 1) {
          group.topics.append(child)
        }
      }
      node.groups.append(group)
    }
    return node
  }
  
  /// The curated child groups of a page: topic sections for reference pages and
  /// chapters for tutorial overviews.
  static func childGroups(of page: JSON) -> [(title: String,
                                              anchor: String,
                                              identifiers: [String])] {
    var groups: [(String, String, [String])] = []
    for section in page["topicSections"].items {
      let title = section["title"]?.stringValue ?? "Topics"
      groups.append((title, section["anchor"]?.stringValue ?? title, section["identifiers"].items.compactMap(\.stringValue)))
    }
    for section in page["sections"].items where section["kind"]?.stringValue == "volume" {
      for chapter in section["chapters"].items {
        let title = chapter["name"]?.stringValue ?? "Chapter"
        groups.append((title, title, chapter["tutorials"].items.compactMap(\.stringValue)))
      }
    }
    return groups
  }
}
