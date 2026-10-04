//
//  SyntaxHighlighter.swift
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

/// A small, line-oriented syntax highlighter for code listings.
///
/// DocC highlights code in the browser, so archives only contain plain text.
/// This covers the common token classes (keywords, strings, comments, numbers,
/// attributes, type names) for Swift and C-family languages, plus comment and
/// string handling for a few others. The output is one HTML fragment per line.
public struct SyntaxHighlighter: Sendable {
  let keywords: Set<String>
  let lineComments: [String]
  let blockComment: (open: String, close: String)?
  let multilineStringDelimiter: String?
  let directivePrefixes: Set<Character>
  let highlightsCapitalizedTypes: Bool
  
  public static func forLanguage(_ language: String?) -> SyntaxHighlighter? {
    switch language?.lowercased() {
      case "swift", "swift-test":
        return SyntaxHighlighter(keywords: swiftKeywords,
                                 lineComments: ["//"],
                                 blockComment: ("/*", "*/"),
                                 multilineStringDelimiter: "\"\"\"",
                                 directivePrefixes: ["@", "#"],
                                 highlightsCapitalizedTypes: true)
      case "objective-c", "objc", "occ", "c", "c++", "cpp", "objective-c++", "objcpp", "m", "h":
        return SyntaxHighlighter(keywords: cKeywords,
                                 lineComments: ["//"],
                                 blockComment: ("/*", "*/"),
                                 multilineStringDelimiter: nil,
                                 directivePrefixes: ["@", "#"],
                                 highlightsCapitalizedTypes: true)
      case "javascript", "js", "typescript", "ts", "json", "java", "kotlin", "rust", "go":
        return SyntaxHighlighter(keywords: scriptKeywords,
                                 lineComments: ["//"],
                                 blockComment: ("/*", "*/"),
                                 multilineStringDelimiter: nil,
                                 directivePrefixes: ["@"],
                                 highlightsCapitalizedTypes: false)
      case "shell", "bash", "sh", "zsh", "console", "python", "py", "ruby", "rb", "yaml",
           "yml", "toml", "perl":
        return SyntaxHighlighter(keywords: shellKeywords,
                                 lineComments: ["#"],
                                 blockComment: nil,
                                 multilineStringDelimiter: nil,
                                 directivePrefixes: [],
                                 highlightsCapitalizedTypes: false)
      default:
        return nil
    }
  }
  
  private enum State {
    case normal
    case blockComment
    case multilineString
  }
  
  public func highlight(lines: [String]) -> [String] {
    var state = State.normal
    return lines.map { highlight(line: $0, state: &state) }
  }
  
  private func highlight(line: String, state: inout State) -> String {
    let chars = Array(line)
    var output = ""
    var index = 0
    
    func hasPrefix(_ token: String, at position: Int) -> Bool {
      let tokenChars = Array(token)
      guard position + tokenChars.count <= chars.count else {
        return false
      }
      return Array(chars[position..<position + tokenChars.count]) == tokenChars
    }
    func find(_ token: String, from position: Int) -> Int? {
      var i = position
      while i < chars.count {
        if hasPrefix(token, at: i) { return i }
        i += 1
      }
      return nil
    }
    func emit(_ range: Range<Int>, _ cssClass: String?) {
      guard !range.isEmpty else { return }
      let text = HTMLRenderer.escape(String(chars[range]))
      if let cssClass {
        output += "<span class=\"tok-\(cssClass)\">\(text)</span>"
      } else {
        output += text
      }
    }
    while index < chars.count {
      switch state {
        case .blockComment:
          let close = blockComment!.close
          if let end = find(close, from: index) {
            emit(index..<end + close.count, "comment")
            index = end + close.count
            state = .normal
          } else {
            emit(index..<chars.count, "comment")
            index = chars.count
          }
          continue
        case .multilineString:
          let delimiter = multilineStringDelimiter!
          if let end = find(delimiter, from: index) {
            emit(index..<end + delimiter.count, "string")
            index = end + delimiter.count
            state = .normal
          } else {
            emit(index..<chars.count, "string")
            index = chars.count
          }
          continue
        case .normal:
          break
      }
      
      let char = chars[index]
      if lineComments.contains(where: { hasPrefix($0, at: index) }) {
        emit(index..<chars.count, "comment")
        break
      }
      if let blockComment, hasPrefix(blockComment.open, at: index) {
        if let end = find(blockComment.close, from: index + blockComment.open.count) {
          emit(index..<end + blockComment.close.count, "comment")
          index = end + blockComment.close.count
        } else {
          emit(index..<chars.count, "comment")
          index = chars.count
          state = .blockComment
        }
        continue
      }
      if let delimiter = multilineStringDelimiter, hasPrefix(delimiter, at: index) {
        if let end = find(delimiter, from: index + delimiter.count) {
          emit(index..<end + delimiter.count, "string")
          index = end + delimiter.count
        } else {
          emit(index..<chars.count, "string")
          index = chars.count
          state = .multilineString
        }
        continue
      }
      if char == "\"" || (char == "'" && multilineStringDelimiter == nil) {
        var end = index + 1
        while end < chars.count && chars[end] != char {
          end += chars[end] == "\\" ? 2 : 1
        }
        end = min(end + 1, chars.count)
        emit(index..<end, "string")
        index = end
        continue
      }
      let previousIsWordCharacter = index > 0 && Self.isWordCharacter(chars[index - 1])
      if char.isNumber && char.isASCII && !previousIsWordCharacter {
        var end = index + 1
        while end < chars.count, chars[end].isHexDigit || "xXoObB_.".contains(chars[end]) {
            // Stop at a range operator such as 0..<10.
          if chars[end] == ".", end + 1 < chars.count, !chars[end + 1].isNumber { break }
          end += 1
        }
        emit(index..<end, "number")
        index = end
        continue
      }
      if directivePrefixes.contains(char),
         index + 1 < chars.count,
         Self.isWordStart(chars[index + 1]) {
        var end = index + 1
        while end < chars.count && Self.isWordCharacter(chars[end]) { end += 1 }
        emit(index..<end, char == "@" ? "attribute" : "keyword")
        index = end
        continue
      }
      if Self.isWordStart(char) && !previousIsWordCharacter {
        var end = index + 1
        while end < chars.count && Self.isWordCharacter(chars[end]) { end += 1 }
        let word = String(chars[index..<end])
        let isMemberAccess = index > 0 && chars[index - 1] == "."
        if keywords.contains(word) && !isMemberAccess {
          emit(index..<end, "keyword")
        } else if highlightsCapitalizedTypes, char.isUppercase {
          emit(index..<end, "type")
        } else {
          emit(index..<end, nil)
        }
        index = end
        continue
      }
      emit(index..<index + 1, nil)
      index += 1
    }
    return output
  }
  
  private static func isWordStart(_ char: Character) -> Bool {
    char.isLetter || char == "_"
  }
  
  private static func isWordCharacter(_ char: Character) -> Bool {
    char.isLetter || char.isNumber || char == "_"
  }
  
  private static let swiftKeywords: Set<String> = [
    "actor", "any", "as", "associatedtype", "async", "await", "borrowing", "break", "case", "catch", "class",
    "consuming", "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else",
    "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if",
    "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro",
    "mutating", "nil", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package",
    "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required", "rethrows",
    "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw",
    "throws", "true", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet", "sending",
  ]
  
  private static let cKeywords: Set<String> = [
    "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
    "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "BOOL",
    "YES", "NO", "nil", "NULL", "self", "super", "id", "instancetype", "nonnull", "nullable", "class",
    "namespace", "template", "typename", "public", "private", "protected", "virtual", "true", "false", "new",
    "delete", "this", "using", "nullptr", "bool", "constexpr", "noexcept", "override", "final",
  ]
  
  private static let scriptKeywords: Set<String> = [
    "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
    "else", "enum", "export", "extends", "false", "finally", "for", "fn", "from", "func", "function", "if",
    "implements", "import", "in", "instanceof", "interface", "let", "mut", "new", "null", "package",
    "private", "protected", "public", "return", "static", "struct", "super", "switch", "this", "throw",
    "true", "try", "type", "typeof", "undefined", "val", "var", "void", "while", "yield",
  ]
  
  private static let shellKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function",
    "return", "export", "local", "def", "class", "import", "from", "as", "with", "try", "except", "finally",
    "raise", "lambda", "None", "True", "False", "and", "or", "not", "is", "pass", "yield", "end", "true",
    "false", "null",
  ]
}
