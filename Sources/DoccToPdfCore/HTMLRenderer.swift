//
//  HTMLRenderer.swift
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

/// Converts the pages of a `DocumentModel` into a single print-oriented HTML document.
///
/// Every documentation page becomes an `<article>` whose id is the page's
/// `anchorID`; headings and topic groups get ids derived from it, so links between
/// pages become in-document `#fragment` links that the PDF composer turns into
/// PDF link annotations.
public final class HTMLRenderer {
  public let model: DocumentModel
  public let options: RenderOptions
  
  public init(model: DocumentModel, options: RenderOptions) {
    self.model = model
    self.options = options
  }
  
  public var documentTitle: String {
    if let title = options.title {
      return title
    }
    if !options.rootPaths.isEmpty, model.roots.count == 1 {
      return model.roots[0].title
    }
    return model.archive.displayName
  }
  
  // MARK: - Document
  
  public func render() -> String {
    var html = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <title>\(Self.escape(documentTitle))</title>
        <style>\(Stylesheet.css(options: options))</style>
        </head><body>
        
        """
    if options.includeCover {
      html += renderCover()
    }
    if let depth = options.tocDepth {
      html += renderTableOfContents(maxDepth: depth)
    }
    for (index, node) in model.orderedNodes.enumerated() {
      html += renderTopic(node, isFirst: index == 0)
    }
    html += "</body></html>\n"
    return html
  }
  
  private func renderCover() -> String {
    let root = model.roots.first
    let eyebrow = model.roots.count == 1
      ? root.flatMap(roleHeading(of:)) ?? "Documentation"
      : "Documentation"
    var html = "<section class=\"cover\" id=\"cover\" data-running-title=\"\">"
    html += "<div class=\"cover-bar\"></div>"
    html += "<p class=\"cover-eyebrow\">\(Self.escape(eyebrow))</p>"
    html += "<h1 class=\"cover-title\">\(Self.escape(documentTitle))</h1>"
    if model.roots.count == 1, let root {
      let abstract = inline(root.page["abstract"].items, root)
      if !abstract.isEmpty {
        html += "<p class=\"cover-abstract\">\(abstract)</p>"
      }
    }
    let date = options.generationDate.formatted(date: .long, time: .omitted)
    html += "<p class=\"cover-meta\">Generated \(Self.escape(date))"
    if let bundle = model.archive.bundleIdentifier {
      html += " from <span class=\"mono\">\(Self.escape(bundle))</span>"
    }
    html += "</p></section>\n"
    return html
  }
  
  private func renderTableOfContents(maxDepth: Int) -> String {
    var html = "<section class=\"toc page-break\" id=\"toc\" data-running-title=\"Contents\">"
      + "<h1>Contents</h1>"
    func entry(title: String, target: String, level: Int, isGroup: Bool) {
      let classes = "toc-entry level-\(min(level, 4))" + (isGroup ? " group" : "")
      html += "<div class=\"\(classes)\" style=\"padding-left:\(Double(level) * 1.3)em\">"
      html += "<a class=\"toc-title\" href=\"#\(target)\">\(Self.escape(title))</a>"
      html += "<span class=\"toc-dots\"></span>"
      html += "<span class=\"toc-num\" data-target=\"\(target)\">\u{2007}</span></div>"
    }
    func walk(_ node: TopicNode, level: Int) {
      entry(title: node.title, target: node.anchorID, level: level, isGroup: false)
      guard node.depth < maxDepth else {
        return
      }
      for group in node.groups where !group.topics.isEmpty {
        entry(title: group.title, target: group.anchorID, level: level + 1, isGroup: true)
        for child in group.topics { walk(child, level: level + 2) }
      }
    }
    for root in model.roots { walk(root, level: 0) }
    html += "</section>\n"
    return html
  }
  
  // MARK: - Topic pages
  
  private func startsNewPage(_ node: TopicNode, isFirst: Bool) -> Bool {
    if isFirst {
      return options.includeCover || options.tocDepth != nil
    }
    switch options.pageBreaks {
      case .all: return true
      case .none: return false
      case .auto: return node.depth <= 1 || node.kind != "symbol" || node.hasCuratedChildren
    }
  }
  
  func renderTopic(_ node: TopicNode, isFirst: Bool) -> String {
    let page = node.page
    let breaks = startsNewPage(node, isFirst: isFirst)
    let isLeaf = node.kind == "symbol" && !node.hasCuratedChildren
    var classes = ["topic", breaks ? "page-break" : (isFirst ? "" : "flow")]
    if isLeaf {
      classes.append("leaf")
    }
    let classList = classes.filter { !$0.isEmpty }.joined(separator: " ")
    var html = "<article class=\"\(classList)\" id=\"\(node.anchorID)\" "
    html += "data-running-title=\"\(Self.escape(node.title))\">"
    
    html += "<header class=\"topic-header\" data-keep-with-next>"
    let ancestors = node.ancestors
    if !ancestors.isEmpty {
      let crumbs = ancestors.map { "<a href=\"#\($0.anchorID)\">\(Self.escape($0.title))</a>" }
      let separator = " <span class=\"sep\">›</span> "
      html += "<nav class=\"breadcrumbs\">\(crumbs.joined(separator: separator))</nav>"
    }
    if let eyebrow = roleHeading(of: node) {
      html += "<p class=\"eyebrow\">\(Self.escape(eyebrow))</p>"
    }
    html += "<h1 class=\"topic-title\">\(Self.breakableTitle(node.title))</h1>"
    let abstract = inline(page["abstract"].items, node)
    if !abstract.isEmpty {
      html += "<p class=\"abstract\">\(abstract)</p>"
    }
    html += renderPlatforms(page["metadata"]?["platforms"].items ?? [])
    html += "</header>"
    
    if let summary = page["deprecationSummary"]?.arrayValue, !summary.isEmpty {
      html += "<div class=\"aside aside-deprecated\"><p class=\"aside-label\">Deprecated</p>"
        + "\(blocks(summary, node))</div>"
    }
    
    for section in page["primaryContentSections"].items {
      html += renderPrimarySection(section, node)
    }
    for section in page["sections"].items {
      html += renderTutorialSection(section, node)
    }
    html += renderTopicSections(node)
    html += renderRelationships(page["relationshipsSections"].items, node)
    html += renderSeeAlso(page["seeAlsoSections"].items, node)
    html += "</article>\n"
    return html
  }
  
  private func roleHeading(of node: TopicNode) -> String? {
    if let heading = node.page["metadata"]?["roleHeading"]?.stringValue {
      return heading
    }
    switch node.kind {
      case "article": return "Article"
      case "tutorial", "project": return "Tutorial"
      case "overview": return "Tutorials"
      default: return nil
    }
  }
  
  private func renderPlatforms(_ platforms: [JSON]) -> String {
    guard !platforms.isEmpty else {
      return ""
    }
    var html = "<div class=\"platforms\">"
    for platform in platforms {
      guard let name = platform["name"]?.stringValue else {
        continue
      }
      var text = Self.escape(name)
      if platform["unavailable"]?.boolValue == true {
        text += " <span class=\"badge\">Unavailable</span>"
      } else if let introduced = platform["introducedAt"]?.stringValue {
        text += " \(Self.escape(introduced))"
        if let deprecated = platform["deprecatedAt"]?.stringValue {
          text += "–\(Self.escape(deprecated))"
        } else {
          text += "+"
        }
      }
      if platform["deprecated"]?.boolValue == true {
        text += " <span class=\"badge deprecated\">Deprecated</span>"
      }
      if platform["beta"]?.boolValue == true {
        text += " <span class=\"badge beta\">Beta</span>"
      }
      html += "<span class=\"platform\">\(text)</span>"
    }
    return html + "</div>"
  }
  
  // MARK: Primary content
  
  private func renderPrimarySection(_ section: JSON, _ node: TopicNode) -> String {
    switch section["kind"]?.stringValue {
      case "declarations":
        return section["declarations"].items.map { renderDeclaration($0, node) }.joined()
      case "content":
        return blocks(section["content"].items, node)
      case "parameters":
        var html = sectionHeading("Parameters", node)
        html += "<dl class=\"parameters\">"
        for parameter in section["parameters"].items {
          html += "<dt><code>\(Self.escape(parameter["name"]?.stringValue ?? ""))</code></dt>"
          html += "<dd>\(blocks(parameter["content"].items, node))</dd>"
        }
        return html + "</dl>"
      case "mentions":
        let identifiers = section["mentions"].items.compactMap(\.stringValue)
        guard !identifiers.isEmpty else {
          return ""
        }
        return "<h3 class=\"mentions-title\">Mentioned In</h3>"
          + topicList(identifiers, node, showAbstracts: false)
      case "properties", "restParameters", "restBody", "restResponses", "restCookies",
           "restHeaders":
        return renderPropertyList(section, node)
      case "restEndpoint":
        let tokens = section["tokens"].items
          .map { Self.escape($0["text"]?.stringValue ?? "") }
          .joined()
        return sectionHeading(section["title"]?.stringValue ?? "URL", node)
        + "<div class=\"declaration\"><code>\(tokens)</code></div>"
      case "attributes":
        var html = sectionHeading(section["title"]?.stringValue ?? "Attributes", node)
          + "<dl class=\"term-list\">"
        for attribute in section["attributes"].items {
          let title = attribute["title"]?.stringValue ?? attribute["kind"]?.stringValue ?? ""
          let value = attribute["value"]?.stringValue
          ?? attribute["values"].items.compactMap(\.stringValue).joined(separator: ", ")
          html += "<dt>\(Self.escape(title))</dt><dd><code>\(Self.escape(value))</code></dd>"
        }
        return html + "</dl>"
      case "possibleValues":
        var html = sectionHeading(section["title"]?.stringValue ?? "Possible Values", node)
          + "<dl class=\"term-list\">"
        for value in section["values"].items {
          html += "<dt><code>\(Self.escape(value["name"]?.stringValue ?? ""))</code></dt>"
          html += "<dd>\(blocks(value["content"].items, node))</dd>"
        }
        return html + "</dl>"
      default:
        return genericSection(section, node)
    }
  }
  
  private func renderDeclaration(_ declaration: JSON, _ node: TopicNode) -> String {
    var html = "<div class=\"declaration\">"
    let languages = declaration["languages"].items.compactMap(\.stringValue)
    if languages.contains(where: { $0 != "swift" }) {
      let names = languages.map(Self.languageName).joined(separator: ", ")
      html += "<p class=\"declaration-label\">\(Self.escape(names))</p>"
    }
    html += "<code>\(tokens(declaration["tokens"].items, node, linkTypes: true))</code></div>"
    return html
  }
  
  private func renderPropertyList(_ section: JSON, _ node: TopicNode) -> String {
    let defaultTitle = section["kind"]?.stringValue == "properties" ? "Properties" : "Parameters"
    var html = sectionHeading(section["title"]?.stringValue ?? defaultTitle, node)
    if let content = section["content"]?.arrayValue {
      html += blocks(content, node)
    }
    let items = section["items"]?.arrayValue
      ?? section["parameters"]?.arrayValue
      ?? section["responses"]?.arrayValue
      ?? []
    html += "<dl class=\"parameters\">"
    for item in items {
      let name = item["name"]?.stringValue ?? item["status"].map { "\($0.intValue ?? 0)" } ?? ""
      var term = "<code>\(Self.escape(name))</code>"
      let type = tokens(item["type"].items, node, linkTypes: true)
      if !type.isEmpty {
        term += " <code class=\"property-type\">\(type)</code>"
      }
      if item["required"]?.boolValue == true {
        term += " <span class=\"badge\">Required</span>"
      }
      if item["deprecated"]?.boolValue == true {
        term += " <span class=\"badge deprecated\">Deprecated</span>"
      }
      html += "<dt>\(term)</dt><dd>\(blocks(item["content"].items, node))</dd>"
    }
    return html + "</dl>"
  }
  
  private func sectionHeading(_ title: String, _ node: TopicNode, anchor: String? = nil) -> String {
    let id = Self.elementID(node.anchorID, anchor ?? title)
    return "<h2 id=\"\(id)\" data-keep-with-next>\(Self.escape(title))</h2>"
  }
  
  private func genericSection(_ section: JSON, _ node: TopicNode) -> String {
    var html = ""
    if let title = section["title"]?.stringValue {
      html += sectionHeading(title, node)
    }
    if let content = section["content"]?.arrayValue {
      html += blocks(content, node)
    }
    return html
  }
  
  // MARK: Topic, relationship, and see-also sections
  
  private func renderTopicSections(_ node: TopicNode) -> String {
    let sections = node.page["topicSections"].items
    guard !sections.isEmpty else {
      return ""
    }
    var html = sectionHeading("Topics", node)
    for section in sections {
      let title = section["title"]?.stringValue ?? "Topics"
      let id = Self.elementID(node.anchorID, section["anchor"]?.stringValue ?? title)
      if section["title"] != nil {
        html += "<h3 id=\"\(id)\" data-keep-with-next>\(Self.escape(title))</h3>"
      } else {
        html += "<span id=\"\(id)\"></span>"
      }
      html += inlineOrBlocks(section["abstract"], node, cssClass: "group-abstract")
      if let discussion = section["discussion"] {
        html += blocks(discussion["content"].items, node)
      }
      let identifiers = section["identifiers"].items.compactMap(\.stringValue)
      html += topicList(identifiers, node, showAbstracts: true)
    }
    return html
  }
  
  private func renderRelationships(_ sections: [JSON], _ node: TopicNode) -> String {
    guard !sections.isEmpty else {
      return ""
    }
    var html = sectionHeading("Relationships", node)
    for section in sections {
      let title = section["title"]?.stringValue ?? ""
      let id = Self.elementID(node.anchorID, title)
      html += "<h3 id=\"\(id)\" data-keep-with-next>\(Self.escape(title))</h3>"
      let identifiers = section["identifiers"].items.compactMap(\.stringValue)
      html += topicList(identifiers, node, showAbstracts: false)
    }
    return html
  }
  
  private func renderSeeAlso(_ sections: [JSON], _ node: TopicNode) -> String {
    guard !sections.isEmpty else {
      return ""
    }
    var html = sectionHeading("See Also", node, anchor: "see-also")
    for section in sections {
      if let title = section["title"]?.stringValue {
        html += "<h3 data-keep-with-next>\(Self.escape(title))</h3>"
      }
      let identifiers = section["identifiers"].items.compactMap(\.stringValue)
      html += topicList(identifiers, node, showAbstracts: true)
    }
    return html
  }
  
  /// A list of links to other pages, each with an optional abstract.
  private func topicList(_ identifiers: [String],
                         _ node: TopicNode,
                         showAbstracts: Bool) -> String {
    guard !identifiers.isEmpty else {
      return ""
    }
    var html = "<div class=\"topic-list\">"
    for identifier in identifiers {
      let reference = node.references[identifier]
      let title = reference?["title"]?.stringValue
        ?? identifier.split(separator: "/").last.map(String.init)
        ?? identifier
      var label: String
      if let fragments = reference?["fragments"]?.arrayValue, !fragments.isEmpty {
        label = "<code class=\"decl\">\(tokens(fragments, node, linkTypes: false))</code>"
      } else if Self.isSymbol(reference) || reference?["type"]?.stringValue == "unresolvable" {
        label = "<code>\(Self.escape(title))</code>"
      } else if let titleContent = reference?["titleInlineContent"]?.arrayValue {
        label = inline(titleContent, node)
      } else {
        label = Self.escape(title)
      }
      if let href = href(forReference: identifier, node) {
        label = "<a href=\"\(Self.escape(href))\">\(label)</a>"
      }
      if reference?["deprecated"]?.boolValue == true {
        label += "<span class=\"badge deprecated\">Deprecated</span>"
      }
      if reference?["beta"]?.boolValue == true {
        label += "<span class=\"badge beta\">Beta</span>"
      }
      let abstract = showAbstracts ? inline(reference?["abstract"].items ?? [], node) : ""
        // Keep a title with its abstract, but not with the next item's title.
      let keep = abstract.isEmpty ? "" : " data-keep-with-next"
      html += "<div class=\"topic-item\"><div class=\"topic-item-title\"\(keep)>\(label)</div>"
      if !abstract.isEmpty {
        html += "<div class=\"topic-item-abstract\">\(abstract)</div>"
      }
      html += "</div>"
    }
    return html + "</div>"
  }
  
  // MARK: - Tutorials
  
  private func renderTutorialSection(_ section: JSON, _ node: TopicNode) -> String {
    switch section["kind"]?.stringValue {
      case "hero":
        var html = ""
        if let chapter = section["chapter"]?.stringValue {
          html += "<p class=\"small\">\(Self.escape(chapter))</p>"
        }
        html += blocks(section["content"].items, node)
        if let minutes = section["estimatedTimeInMinutes"]?.intValue {
          html += "<p class=\"small\">Estimated time: \(minutes) min</p>"
        }
        if let projectFiles = section["projectFiles"]?.stringValue,
           let href = href(forReference: projectFiles, node) {
          html += "<p class=\"small\"><a href=\"\(Self.escape(href))\">Project files</a></p>"
        }
        return html
      case "volume":
        var html = ""
        if let name = section["name"]?.stringValue {
          html += sectionHeading(name, node)
        }
        html += blocks(section["content"].items, node)
        for chapter in section["chapters"].items {
          let name = chapter["name"]?.stringValue ?? "Chapter"
          let id = Self.elementID(node.anchorID, name)
          html += "<h3 id=\"\(id)\" data-keep-with-next>\(Self.escape(name))</h3>"
          html += blocks(chapter["content"].items, node)
          let identifiers = chapter["tutorials"].items.compactMap(\.stringValue)
          html += topicList(identifiers, node, showAbstracts: true)
        }
        return html
      case "tasks":
        var html = ""
        for (index, task) in section["tasks"].items.enumerated() {
          let title = task["title"]?.stringValue ?? "Section \(index + 1)"
          let id = Self.elementID(node.anchorID, task["anchor"]?.stringValue ?? title)
          html += "<p class=\"eyebrow\" data-keep-with-next>Section \(index + 1)</p>"
          html += "<h2 id=\"\(id)\" class=\"task-title\" data-keep-with-next>"
            + "\(Self.escape(title))</h2>"
          for content in task["contentSection"].items {
            html += blocks(content["content"].items, node)
            if let media = content["media"]?.stringValue {
              html += mediaHTML(media, node)
            }
          }
          html += renderSteps(task["stepsSection"].items, node)
        }
        return html
      case "assessments":
        var html = sectionHeading("Check Your Understanding",
                                  node,
                                  anchor: section["anchor"]?.stringValue)
        for (index, assessment) in section["assessments"].items.enumerated() {
          html += "<div class=\"assessment\"><p class=\"step-label\">Question \(index + 1)</p>"
          html += blocks(assessment["title"].items, node)
          html += blocks(assessment["content"].items, node)
          html += "<ol class=\"choices\" type=\"A\">"
          for choice in assessment["choices"].items {
            let correct = choice["isCorrect"]?.boolValue == true
            let content = blocks(choice["content"].items, node)
            html += "<li class=\"\(correct ? "correct" : "")\">\(content)"
            if correct {
              html += "<span class=\"badge correct\">Correct</span>"
            }
            html += "</li>"
          }
          html += "</ol></div>"
        }
        return html
      case "callToAction":
        var html = ""
        if let title = section["title"]?.stringValue {
          html += sectionHeading(title, node)
        }
        html += inlineOrBlocks(section["abstract"], node, cssClass: nil)
        if let action = section["action"], action["type"]?.stringValue == "reference",
           let identifier = action["identifier"]?.stringValue {
          html += topicList([identifier], node, showAbstracts: false)
        }
        return html
      case "contentAndMedia", "contentAndMediaGroup":
        var html = ""
        if let title = section["title"]?.stringValue {
          html += sectionHeading(title, node)
        }
        html += blocks(section["content"].items, node)
        if let media = section["media"]?.stringValue {
          html += mediaHTML(media, node)
        }
        for item in section["items"].items { html += renderTutorialSection(item, node) }
        return html
      default:
        var html = genericSection(section, node)
        for item in section["items"].items { html += renderTutorialSection(item, node) }
        return html
    }
  }
  
  private func renderSteps(_ items: [JSON], _ node: TopicNode) -> String {
    var html = ""
    var stepNumber = 0
    for item in items {
      guard item["type"]?.stringValue == "step" else {
        html += block(item, node)
        continue
      }
      stepNumber += 1
      html += "<div class=\"step\"><p class=\"step-label\">Step \(stepNumber)</p>"
      html += blocks(item["content"].items, node)
      if let media = item["media"]?.stringValue {
        html += mediaHTML(media, node)
      }
      if let code = item["code"]?.stringValue {
        html += fileHTML(code, node)
      }
      html += "<div class=\"small\">\(blocks(item["caption"].items, node))</div>"
      html += "</div>"
    }
    return html
  }
  
  private func fileHTML(_ identifier: String, _ node: TopicNode) -> String {
    guard let file = node.references[identifier], file["type"]?.stringValue == "file" else {
      return ""
    }
    var html = ""
    if let name = file["fileName"]?.stringValue {
      html += "<p class=\"code-file-name\">\(Self.escape(name))</p>"
    }
    let highlighted = Set(file["highlights"].items.compactMap { $0["line"]?.intValue })
    html += codeListing(file["content"].items.compactMap(\.stringValue),
                        syntax: file["syntax"]?.stringValue ?? file["fileType"]?.stringValue,
                        highlightedLines: highlighted)
    return html
  }
  
  // MARK: - Blocks
  
  func blocks(_ items: [JSON], _ node: TopicNode) -> String {
    items.map { block($0, node) }.joined()
  }
  
  func block(_ item: JSON, _ node: TopicNode) -> String {
    switch item["type"]?.stringValue {
      case "paragraph":
        let content = item["inlineContent"].items
        if content.count == 1,
           content[0]["type"]?.stringValue == "image",
           let id = content[0]["identifier"]?.stringValue {
          return figure(id, node, caption: content[0]["metadata"]?["abstract"]?.arrayValue)
        }
        return "<p>\(inline(content, node))</p>"
      case "heading":
        let level = min(max(item["level"]?.intValue ?? 2, 2), 6)
        let text = item["text"]?.stringValue ?? ""
        let id = Self.elementID(node.anchorID, item["anchor"]?.stringValue ?? text)
        return "<h\(level) id=\"\(id)\" data-keep-with-next>\(Self.escape(text))</h\(level)>"
      case "aside":
        let style = (item["style"]?.stringValue ?? "note").lowercased()
        let known = ["note", "tip", "important", "warning", "experiment", "deprecated"]
        let name = item["name"]?.stringValue ?? style.prefix(1).uppercased() + style.dropFirst()
        return "<div class=\"aside aside-\(known.contains(style) ? style : "note")\">"
          + "<p class=\"aside-label\">\(Self.escape(name))</p>"
          + "\(blocks(item["content"].items, node))</div>"
      case "codeListing":
        return codeListing(item["code"].items.compactMap(\.stringValue),
                           syntax: item["syntax"]?.stringValue)
      case "unorderedList":
        let items = item["items"].items.map { "<li>\(blocks($0["content"].items, node))</li>" }
        return "<ul>" + items.joined() + "</ul>"
      case "orderedList":
        let start = item["start"]?.intValue.map { " start=\"\($0)\"" } ?? ""
        let items = item["items"].items.map { "<li>\(blocks($0["content"].items, node))</li>" }
        return "<ol\(start)>" + items.joined() + "</ol>"
      case "termList":
        var html = "<dl class=\"term-list\">"
        for entry in item["items"].items {
          html += "<dt>\(inline(entry["term"]?["inlineContent"].items ?? [], node))</dt>"
          html += "<dd>\(blocks(entry["definition"]?["content"].items ?? [], node))</dd>"
        }
        return html + "</dl>"
      case "table":
        return table(item, node)
      case "small":
        return "<p class=\"small\">\(inline(item["inlineContent"].items, node))</p>"
      case "tabNavigator":
        return item["tabs"].items.map { tab in
          let title = Self.escape(tab["title"]?.stringValue ?? "")
          return "<div class=\"tab\"><p class=\"tab-title\" data-keep-with-next>\(title)</p>"
            + blocks(tab["content"].items, node) + "</div>"
        }.joined()
      case "links":
        return topicList(item["items"].items.compactMap(\.stringValue), node, showAbstracts: true)
      case "row":
        let columns = max(item["numberOfColumns"]?.intValue ?? item["columns"].items.count, 1)
        var html = "<div class=\"row\" "
          + "style=\"grid-template-columns:repeat(\(columns),minmax(0,1fr))\">"
        for column in item["columns"].items {
          let span = max(column["size"]?.intValue ?? 1, 1)
          let content = blocks(column["content"].items, node)
          html += "<div style=\"grid-column:span \(span)\">\(content)</div>"
        }
        return html + "</div>"
      case "video":
        return item["identifier"]?.stringValue.map { mediaHTML($0, node) } ?? ""
      case "thematicBreak":
        return "<hr>"
      case "dictionaryExample":
        var html = blocks(item["summary"].items, node)
        if let example = item["example"] {
          html += codeListing(Self.codeLines(of: example),
                              syntax: example["syntax"]?.stringValue ?? "json")
        }
        return html
      case "endpointExample":
        var html = blocks(item["summary"].items, node)
        for part in ["request", "response"] {
          guard let example = item[part] else {
            continue
          }
          html += "<p class=\"code-file-name\">\(part.capitalized)</p>"
          let lines = Self.codeLines(of: example)
          html += codeListing(lines, syntax: example["type"]?.stringValue)
        }
        return html
      case "step":
        return renderSteps([item], node)
      default:
        if let content = item["content"]?.arrayValue {
          return blocks(content, node)
        }
        if let content = item["inlineContent"]?.arrayValue {
          return "<p>\(inline(content, node))</p>"
        }
        return ""
    }
  }
  
  private func inlineOrBlocks(_ value: JSON?, _ node: TopicNode, cssClass: String?) -> String {
    guard let items = value?.arrayValue, !items.isEmpty else {
      return ""
    }
    let classAttribute = cssClass.map { " class=\"\($0)\"" } ?? ""
    if items.contains(where: { $0["type"]?.stringValue == "paragraph" }) {
      return "<div\(classAttribute)>\(blocks(items, node))</div>"
    }
    return "<p\(classAttribute)>\(inline(items, node))</p>"
  }
  
  /// The lines of all code blocks of an endpoint or dictionary example.
  private static func codeLines(of example: JSON) -> [String] {
    example["content"].items
      .compactMap { $0["code"]?.arrayValue }
      .flatMap { $0 }
      .compactMap(\.stringValue)
  }

  private func codeListing(_ lines: [String],
                           syntax: String?,
                           highlightedLines: Set<Int> = []) -> String {
    let rendered = SyntaxHighlighter.forLanguage(syntax)?.highlight(lines: lines)
      ?? lines.map(Self.escape)
    var html = "<pre class=\"code-listing\"><code>"
    for (index, line) in rendered.enumerated() {
      let cssClass = highlightedLines.contains(index + 1) ? "line hl" : "line"
      html += "<span class=\"\(cssClass)\">\(line.isEmpty ? "\u{200B}" : line)</span>"
    }
    return html + "</code></pre>"
  }
  
  private func table(_ item: JSON, _ node: TopicNode) -> String {
    let header = item["header"]?.stringValue ?? "none"
    let extended = item["extendedData"]?.objectValue ?? [:]
    let alignments = item["alignments"].items.map { $0.stringValue ?? "unset" }
    var html = "<table>"
    for (rowIndex, row) in item["rows"].items.enumerated() {
      html += "<tr>"
      for (columnIndex, cell) in row.items.enumerated() {
        var attributes = ""
        if let data = extended["\(rowIndex)_\(columnIndex)"] {
          let colspan = data["colspan"]?.intValue ?? 1
          let rowspan = data["rowspan"]?.intValue ?? 1
          if colspan == 0 || rowspan == 0 {
            continue
          }
          if colspan > 1 {
            attributes += " colspan=\"\(colspan)\""
          }
          if rowspan > 1 {
            attributes += " rowspan=\"\(rowspan)\""
          }
        }
        if columnIndex < alignments.count,
           ["left", "center", "right"].contains(alignments[columnIndex]) {
          attributes += " style=\"text-align:\(alignments[columnIndex])\""
        }
        let isHeader = ((header == "row" || header == "both") && rowIndex == 0)
        || ((header == "column" || header == "both") && columnIndex == 0)
        let tag = isHeader ? "th" : "td"
        html += "<\(tag)\(attributes)>\(blocks(cell.items, node))</\(tag)>"
      }
      html += "</tr>"
    }
    return html + "</table>"
  }
  
  // MARK: - Media
  
  private func figure(_ identifier: String, _ node: TopicNode, caption: [JSON]?) -> String {
    guard let image = imageTag(identifier, node, inline: false) else {
      return ""
    }
    var html = "<figure>\(image)"
    if let caption, !caption.isEmpty {
      html += "<figcaption>\(inline(caption, node))</figcaption>"
    }
    return html + "</figure>"
  }
  
  private func mediaHTML(_ identifier: String, _ node: TopicNode) -> String {
    guard let reference = node.references[identifier] else {
      return ""
    }
    switch reference["type"]?.stringValue {
      case "image":
        return figure(identifier, node, caption: nil)
      case "video":
        // Videos cannot play in a PDF; show the poster frame and a caption instead.
        var html = "<figure class=\"video\">"
        if let poster = reference["poster"]?.stringValue,
           let image = imageTag(poster, node, inline: false) {
          html += image
        }
        let alt = reference["alt"]?.stringValue.map { ": \(Self.escape($0))" } ?? ""
        return html + "<figcaption>Video\(alt)</figcaption></figure>"
      default:
        return ""
    }
  }
  
  /// An `<img>` for an image reference, preferring the light, high-resolution variant.
  private func imageTag(_ identifier: String, _ node: TopicNode, inline: Bool) -> String? {
    guard let reference = node.references[identifier] else {
      return nil
    }
    let variants = reference["variants"].items.compactMap {
      variant -> (url: String, traits: [String])? in
        guard let url = variant["url"]?.stringValue else {
          return nil
        }
        return (url, variant["traits"].items.compactMap(\.stringValue))
    }
    let light = variants.filter { !$0.traits.contains("dark") }
    let candidates = light.isEmpty ? variants : light
    func scale(_ traits: [String]) -> Int {
      traits.compactMap { $0.hasSuffix("x") ? Int($0.dropLast()) : nil }.first ?? 1
    }
    guard let best = candidates.max(by: { scale($0.traits) < scale($1.traits) }),
          let url = model.archive.assetURL(best.url) else {
      return nil
    }
    let alt = Self.escape(reference["alt"]?.stringValue ?? "")
    let source = Self.escape(url.absoluteString)
    let factor = scale(best.traits)
    // A density descriptor makes WebKit lay out a 2x image at half its pixel
    // size while keeping full resolution in the PDF.
    let sourceAttribute = factor > 1 ? "srcset=\"\(source) \(factor)x\"" : "src=\"\(source)\""
    return "<img \(sourceAttribute) alt=\"\(alt)\"\(inline ? " class=\"inline\"" : "")>"
  }
  
  // MARK: - Inline content
  
  func inline(_ items: [JSON], _ node: TopicNode) -> String {
    items.map { inlineItem($0, node) }.joined()
  }
  
  private func inlineItem(_ item: JSON, _ node: TopicNode) -> String {
    switch item["type"]?.stringValue {
      case "text":
        return Self.escape(item["text"]?.stringValue ?? "")
      case "codeVoice":
        return "<code>\(Self.escape(item["code"]?.stringValue ?? ""))</code>"
      case "emphasis":
        return "<em>\(inline(item["inlineContent"].items, node))</em>"
      case "strong", "inlineHead":
        return "<strong>\(inline(item["inlineContent"].items, node))</strong>"
      case "newTerm":
        return "<em class=\"term\">\(inline(item["inlineContent"].items, node))</em>"
      case "subscript":
        return "<sub>\(inline(item["inlineContent"].items, node))</sub>"
      case "superscript":
        return "<sup>\(inline(item["inlineContent"].items, node))</sup>"
      case "strikethrough":
        return "<s>\(inline(item["inlineContent"].items, node))</s>"
      case "image":
        return item["identifier"]?.stringValue.flatMap { imageTag($0, node, inline: true) } ?? ""
      case "reference":
        return referenceLink(item, node)
      case "link":
        let destination = item["destination"]?.stringValue ?? ""
        let title = item["title"]?.stringValue ?? destination
        return "<a href=\"\(Self.escape(destination))\">\(Self.escape(title))</a>"
      default:
        if let content = item["inlineContent"]?.arrayValue {
          return inline(content, node)
        }
        return Self.escape(item["text"]?.stringValue ?? item["code"]?.stringValue ?? "")
    }
  }
  
  private func referenceLink(_ item: JSON, _ node: TopicNode) -> String {
    guard let identifier = item["identifier"]?.stringValue else {
      return ""
    }
    let reference = node.references[identifier]
    let content: String
    if let overriding = item["overridingTitleInlineContent"]?.arrayValue {
      content = inline(overriding, node)
    } else if let overriding = item["overridingTitle"]?.stringValue {
      content = Self.escape(overriding)
    } else if let titleContent = reference?["titleInlineContent"]?.arrayValue {
      content = inline(titleContent, node)
    } else {
      let title = reference?["title"]?.stringValue ?? identifier
      content = Self.isSymbol(reference) || reference?["type"]?.stringValue == "unresolvable"
      ? "<code>\(Self.escape(title))</code>" : Self.escape(title)
    }
    guard item["isActive"]?.boolValue != false,
          let href = href(forReference: identifier, node) else {
      return content
    }
    return "<a href=\"\(Self.escape(href))\">\(content)</a>"
  }
  
  /// Declaration tokens; type identifiers link to their pages when those are part of the book.
  private func tokens(_ tokens: [JSON], _ node: TopicNode, linkTypes: Bool) -> String {
    tokens.map { token in
      let text = Self.escape(token["text"]?.stringValue ?? "")
      let kind = token["kind"]?.stringValue ?? "text"
      let cssClass: String? = switch kind {
        case "keyword": "keyword"
        case "attribute": "attribute"
        case "number": "number"
        case "string": "string"
        case "typeIdentifier": "type"
        case "genericParameter": "generic"
        case "identifier": "identifier"
        case "externalParam", "label": "param"
        case "internalParam": "internal-param"
        default: nil
      }
      guard let cssClass else {
        return text
      }
      if linkTypes, kind == "typeIdentifier", let identifier = token["identifier"]?.stringValue,
         let href = href(forReference: identifier, node) {
        return "<a class=\"tok-\(cssClass)\" href=\"\(Self.escape(href))\">\(text)</a>"
      }
      return "<span class=\"tok-\(cssClass)\">\(text)</span>"
    }.joined()
  }
  
  // MARK: - Links
  
  /// The link target for a reference: an in-document fragment for pages that are part
  /// of the book, the URL for external links, and `nil` for anything else.
  func href(forReference identifier: String, _ node: TopicNode) -> String? {
    guard let reference = node.references[identifier] else {
      return nil
    }
    switch reference["type"]?.stringValue {
      case "link":
        return reference["url"]?.stringValue
      case "topic", "section":
        guard let url = reference["url"]?.stringValue else {
          return nil
        }
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
          return url
        }
        guard let target = model.node(forPath: url) else {
          return nil
        }
        if let hash = url.firstIndex(of: "#") {
          let fragment = String(url[url.index(after: hash)...])
          return "#" + Self.elementID(target.anchorID, fragment.removingPercentEncoding ?? fragment)
        }
        return "#" + target.anchorID
      case "download":
        return reference["url"]?.stringValue.flatMap { model.archive.assetURL($0)?.absoluteString }
      default:
        return nil
    }
  }
  
  // MARK: - Utilities
  
  static func isSymbol(_ reference: JSON?) -> Bool {
    reference?["kind"]?.stringValue == "symbol" || reference?["role"]?.stringValue == "symbol"
  }
  
  static func languageName(_ identifier: String) -> String {
    switch identifier {
      case "swift": "Swift"
      case "occ", "objc", "objective-c": "Objective-C"
      case "data": "Data"
      default: identifier
    }
  }
  
  /// An HTML id for an anchor inside a page. Page ids (`t12`) never contain a hyphen,
  /// so the page id can always be recovered from the prefix.
  public static func elementID(_ base: String, _ anchor: String) -> String {
    let sanitized = anchor.unicodeScalars.map { scalar -> String in
      let allowed = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        || scalar == "-" || scalar == "_"
      return allowed ? String(scalar) : "_"
    }.joined()
    return "\(base)-\(sanitized)"
  }
  
  /// Escapes a symbol name and allows line breaks after dots and between camel-case
  /// words, so long names such as `Foo.BarStrategy.millisecondsSince1970` wrap
  /// at sensible places instead of in the middle of a word.
  static func breakableTitle(_ title: String) -> String {
    var result = ""
    var previous: Character?
    for character in title {
      if let previous, character.isUppercase, previous.isLowercase {
        result += "<wbr>"
      }
      result += escape(String(character))
      if character == "." || character == "(" || character == ":" || character == "," {
        result += "<wbr>"
      }
      previous = character
    }
    return result
  }
  
  public static func escape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for character in text {
      switch character {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        default: result.append(character)
      }
    }
    return result
  }
}
