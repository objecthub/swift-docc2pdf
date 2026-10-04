//
//  Stylesheet.swift
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

/// Print stylesheet modelled on DocC's web appearance. One CSS pixel maps to one
/// PDF point, so sizes below are effectively in points.
enum Stylesheet {
  static func css(options: RenderOptions) -> String {
    let width = options.contentWidth
    let height = options.contentHeight
    return """
      :root { color-scheme: light; }
      * { box-sizing: border-box; }
      html { background: #fff; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      body {
        margin: 0; width: \(width)px; background: #fff; color: #1d1d1f;
        font-family: -apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
        font-size: \(options.fontSize)px; line-height: 1.47; overflow-wrap: break-word;
        -webkit-text-size-adjust: none; text-rendering: optimizeLegibility;
      }
      a { color: #0066cc; text-decoration: none; }
      p { margin: 0 0 0.8em; }
      code, pre, .mono { font-family: ui-monospace, "SF Mono", Menlo, Monaco, monospace; }
      code { font-size: 0.92em; }
      sub, sup { line-height: 0; }
      h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 1.3em 0 0.5em; }
      h2 {
        font-size: 1.55em; padding-top: 0.55em; border-top: 1px solid #d2d2d7; margin-top: 1.5em;
      }
      h3 { font-size: 1.25em; }
      h4 { font-size: 1.1em; }
      h5, h6 { font-size: 1em; }
      img { max-width: 100%; max-height: \(height * 0.9)px; height: auto; }
      img.inline { max-height: 1.4em; vertical-align: middle; }
      figure { margin: 0 0 1em; text-align: center; }
      figcaption { font-size: 0.85em; color: #6e6e73; margin-top: 0.4em; }
      hr { border: 0; border-top: 1px solid #d2d2d7; margin: 1.5em 0; }
      ul, ol { margin: 0 0 1em; padding-left: 1.6em; }
      li { margin: 0.2em 0; }
      li > p { margin-bottom: 0.4em; }
      
      /* Cover */
      .cover {
        height: \(height - 1)px; display: flex; flex-direction: column; justify-content: center;
        padding: 0 0 15%;
      }
      .cover-bar {
        width: 56px; height: 6px; border-radius: 3px; background: #0066cc; margin-bottom: 1.6em;
      }
      .cover-eyebrow { font-size: 1.15em; font-weight: 600; color: #6e6e73; margin: 0; }
      .cover-title {
        font-size: 3.4em; font-weight: 700; line-height: 1.08; letter-spacing: -0.015em;
        margin: 0.15em 0 0.4em; border: 0; padding: 0;
      }
      .cover-abstract { font-size: 1.4em; line-height: 1.4; color: #424245; max-width: 88%; }
      .cover-meta { margin-top: 2.5em; color: #6e6e73; font-size: 0.95em; }
      
      /* Table of contents */
      .toc > h1 { font-size: 2.2em; font-weight: 700; margin: 0 0 1em; }
      .toc-entry { display: flex; align-items: baseline; gap: 0.4em; margin: 0.2em 0; }
      .toc-title { flex: 0 1 auto; color: #1d1d1f; }
      .toc-dots {
        flex: 1 1 auto; min-width: 1.5em; border-bottom: 1px dotted #b0b0b5; position: relative;
        top: -0.3em;
      }
      .toc-num {
        flex: 0 0 2.6em; text-align: right; color: #424245; font-variant-numeric: tabular-nums;
      }
      .toc-entry.level-0 { font-weight: 600; font-size: 1.1em; margin-top: 1em; }
      .toc-entry.group .toc-title {
        font-weight: 600; font-size: 0.85em; color: #6e6e73; text-transform: uppercase;
        letter-spacing: 0.03em;
      }
      .toc-entry.group { margin-top: 0.6em; }
      
      /* Documentation pages */
      .topic { margin: 0 0 2em; }
      .topic.flow { border-top: 2px solid #1d1d1f; padding-top: 1.2em; margin-top: 2em; }
      .topic-header { margin-bottom: 1.2em; }
      .breadcrumbs { font-size: 0.82em; color: #6e6e73; margin-bottom: 0.9em; }
      .breadcrumbs a { color: #6e6e73; }
      .breadcrumbs .sep { padding: 0 0.2em; }
      .eyebrow { font-size: 1.05em; font-weight: 600; color: #6e6e73; margin: 0 0 0.15em; }
      .topic-title {
        font-size: 2.4em; font-weight: 700; letter-spacing: -0.01em; line-height: 1.12;
        margin: 0 0 0.35em; border: 0; padding: 0;
      }
      .topic.leaf .topic-title { font-size: 1.75em; }
      .abstract { font-size: 1.2em; line-height: 1.42; margin: 0 0 0.6em; }
      .platforms {
        display: flex; flex-wrap: wrap; gap: 0.25em 1.2em; font-size: 0.85em; color: #6e6e73;
        margin: 0.6em 0 0;
      }
      
      .declaration {
        background: #f5f5f7; border: 1px solid #e3e3e8; border-radius: 8px; padding: 0.8em 1.1em;
        margin: 0 0 1.4em;
        font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.95em;
        line-height: 1.55;
        white-space: pre-wrap; overflow-wrap: anywhere;
      }
      .declaration code { font-size: 1em; }
      .declaration-label {
        font-family: -apple-system, sans-serif; font-size: 0.8em; color: #6e6e73; margin: 0 0 0.3em;
        white-space: normal;
      }
      .declaration a, a.tok-type { color: #703daa; }
      .tok-keyword { color: #ad3da4; }
      .tok-attribute { color: #947100; }
      .tok-number { color: #272ad8; }
      .tok-string { color: #c41a16; }
      .tok-type { color: #703daa; }
      .tok-comment { color: #5d6c79; }
      .tok-identifier { font-weight: 600; }
      .tok-param { color: #1d1d1f; }
      .tok-internal-param { color: #6e6e73; }
      
      pre.code-listing {
        background: #f5f5f7; border-radius: 8px; padding: 0.75em 1.1em; margin: 0 0 1.1em;
        font-size: 0.86em; line-height: 1.5; white-space: pre-wrap; overflow-wrap: anywhere;
        text-align: left;
      }
      pre.code-listing code { font-size: 1em; }
      pre .line { display: block; min-height: 1.5em; }
      pre .line.hl { background: #fff1b8; margin: 0 -1.1em; padding: 0 1.1em; }
      .code-file-name {
        font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.82em; color: #6e6e73;
        margin: 0 0 0.3em;
      }
      
      .aside {
        border-left: 4px solid #8e8e93; background: #f5f5f7; border-radius: 6px;
        padding: 0.7em 1.1em; margin: 0 0 1.1em;
      }
      .aside > :last-child { margin-bottom: 0; }
      .aside-label { font-weight: 600; margin: 0 0 0.25em; }
      .aside-tip { border-color: #1d8f3a; background: #f0f8f2; }
      .aside-tip .aside-label { color: #1a7f33; }
      .aside-important { border-color: #c45c00; background: #fff7ee; }
      .aside-important .aside-label { color: #a84f00; }
      .aside-warning, .aside-deprecated { border-color: #d70015; background: #fff2f3; }
      .aside-warning .aside-label, .aside-deprecated .aside-label { color: #b8000f; }
      .aside-experiment { border-color: #8f45c9; background: #f8f2fc; }
      .aside-experiment .aside-label { color: #7a35b0; }
      
      table { border-collapse: collapse; margin: 0 0 1.1em; max-width: 100%; }
      th, td {
        border: 1px solid #d2d2d7; padding: 0.35em 0.7em; text-align: left; vertical-align: top;
      }
      th { background: #f5f5f7; font-weight: 600; }
      th > :last-child, td > :last-child { margin-bottom: 0; }
      
      dl { margin: 0 0 1em; }
      dt { font-weight: 600; margin-top: 0.6em; }
      dd { margin: 0.15em 0 0.5em 1.6em; }
      dd > :last-child { margin-bottom: 0; }
      dl.parameters dt { font-weight: 400; }
      .property-type { color: #6e6e73; }
      
      .mentions-title { font-size: 1em; color: #6e6e73; margin-top: 0; }
      .group-abstract { color: #424245; }
      .topic-list { margin: 0 0 1.2em; }
      .topic-item { margin: 0 0 0.75em; }
      .topic-item-title code { font-size: 0.95em; }
      .topic-item-title code.decl, .topic-item-title code.decl .tok-param { color: #0066cc; }
      .topic-item-title a code.decl span { color: inherit; font-weight: inherit; }
      .topic-item-title code.decl .tok-identifier { font-weight: 600; }
      .topic-item-abstract { color: #424245; margin-top: 0.1em; padding-left: 1.4em; }
      .topic-item-abstract > :last-child { margin-bottom: 0; }
      
      .badge {
        display: inline-block; font-family: -apple-system, sans-serif; font-size: 0.72em;
        font-weight: 500; line-height: 1.3;
        border: 1px solid currentColor; border-radius: 4px; padding: 0 0.35em; margin-left: 0.5em;
        color: #6e6e73; vertical-align: 0.1em;
      }
      .badge.deprecated { color: #d70015; }
      .badge.beta { color: #8f45c9; }
      .badge.correct { color: #1d8f3a; }
      .small { font-size: 0.85em; color: #6e6e73; }
      
      .row { display: grid; gap: 1.2em; margin: 0 0 1em; }
      .tab-title {
        font-weight: 600; font-size: 0.85em; color: #6e6e73; text-transform: uppercase;
        letter-spacing: 0.03em; margin: 0.8em 0 0.3em;
      }
      .task-title { border-top: 0; padding-top: 0; margin-top: 0.2em; }
      .step, .assessment {
        border: 1px solid #e3e3e8; border-radius: 8px; padding: 0.8em 1.1em; margin: 0 0 1em;
      }
      .step > :last-child, .assessment > :last-child { margin-bottom: 0; }
      .step-label { font-weight: 600; font-size: 0.85em; color: #6e6e73; margin: 0 0 0.3em; }
      ol.choices li.correct { font-weight: 500; }
      """
  }
}
