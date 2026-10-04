//
//  DocumentationArchive.swift
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

public enum DoccToPdfError: Error, CustomStringConvertible {
  case notAnArchive(URL)
  case pageNotFound(String)
  case renderingFailed(String)
  case writeFailed(URL)
  
  public var description: String {
    switch self {
      case .notAnArchive(let url):
        return "\(url.path) is not a DocC archive (no data/ directory with render JSON found)."
      case .pageNotFound(let path):
        return "No documentation page found at \(path)."
      case .renderingFailed(let message):
        return "Rendering failed: \(message)"
      case .writeFailed(let url):
        return "Could not write PDF to \(url.path)."
    }
  }
}

/// Read access to the render JSON and assets inside a `.doccarchive` directory.
public final class DocumentationArchive {
  public let url: URL
  public let displayName: String
  public let bundleIdentifier: String?
  
  /// Lower-cased documentation path (e.g. `/documentation/mykit/foo`) → JSON file.
  private let files: [String: URL]
  
  /// Paths in the order they appear on disk, used for stable fallback ordering.
  public let allPaths: [String]
  private var cache: [String: JSON] = [:]
  
  public init(url: URL) throws {
    self.url = url.standardizedFileURL
    let dataDirectory = self.url.appendingPathComponent("data", isDirectory: true)
    var files: [String: URL] = [:]
    var paths: [String] = []
    let enumerator = FileManager.default.enumerator(at: dataDirectory,
                                                    includingPropertiesForKeys: nil)
    if let enumerator {
      let prefixLength = dataDirectory.resolvingSymlinksInPath().path.count
      for case let file as URL in enumerator where file.pathExtension == "json" {
        var path = String(file.resolvingSymlinksInPath().path.dropFirst(prefixLength))
        path.removeLast(".json".count)
        let key = path.lowercased()
        if files[key] == nil {
          files[key] = file
          paths.append(key)
        }
      }
    }
    guard !files.isEmpty else {
      throw DoccToPdfError.notAnArchive(url)
    }
    self.files = files
    self.allPaths = paths.sorted()
    
    let metadataURL = self.url.appendingPathComponent("metadata.json")
    let metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSON(data: $0) }
    self.bundleIdentifier = metadata?["bundleID"]?.stringValue
    self.displayName = metadata?["bundleDisplayName"]?.stringValue
    ?? url.deletingPathExtension().lastPathComponent
  }
  
  public func contains(path: String) -> Bool {
    files[Self.normalize(path)] != nil
  }
  
  /// Loads the render node for a documentation path such as `/documentation/mykit/foo`.
  public func page(at path: String) throws -> JSON {
    let key = Self.normalize(path)
    if let cached = cache[key] {
      return cached
    }
    guard let file = files[key] else {
      throw DoccToPdfError.pageNotFound(path)
    }
    let json = try JSON(data: Data(contentsOf: file))
    cache[key] = json
    return json
  }
  
  /// The top-level pages of the archive: module pages and tutorial overviews.
  public func rootPaths() -> [String] {
    // The navigator index lists the roots in the order DocC presents them.
    let indexURL = url.appendingPathComponent("index/index.json")
    if let data = try? Data(contentsOf: indexURL), let index = try? JSON(data: data),
       let languages = index["interfaceLanguages"]?.objectValue {
      let nodes = languages["swift"] ?? languages.sorted { $0.key < $1.key }.first?.value
      let roots = nodes.items
        .compactMap { $0["path"]?.stringValue }
        .filter(contains(path:))
        .map(Self.normalize)
      // Reference documentation first, then tutorials.
      let ordered = roots.filter { !$0.hasPrefix("/tutorials") }
        + roots.filter { $0.hasPrefix("/tutorials") }
      if !ordered.isEmpty {
        return ordered
      }
    }
    // Fall back to the JSON files directly below data/documentation and data/tutorials.
    return allPaths.filter { path in
      let components = path.split(separator: "/")
      return components.count == 2
        && (components[0] == "documentation" || components[0] == "tutorials")
    }
  }
  
  /// File URL of an asset referenced by an absolute archive path such as `/images/foo.png`.
  public func assetURL(_ path: String) -> URL? {
    if let url = URL(string: path), let scheme = url.scheme, !scheme.isEmpty {
      return url
    }
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    let decoded = relative.removingPercentEncoding ?? relative
    return url.appendingPathComponent(decoded)
  }
  
  /// Normalizes a documentation URL or path to the lower-cased path used as lookup key.
  public static func normalize(_ path: String) -> String {
    var path = path
    if let hash = path.firstIndex(of: "#") {
      path = String(path[..<hash])
    }
    if let query = path.firstIndex(of: "?") {
      path = String(path[..<query])
    }
    if let range = path.range(of: "://") {
      // doc://bundle/documentation/... → /documentation/...
      let afterScheme = path[range.upperBound...]
      path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
    }
    if !path.hasPrefix("/") {
      path = "/" + path
    }
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path.lowercased()
  }
}
