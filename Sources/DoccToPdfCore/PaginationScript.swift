//
//  PaginationScript.swift
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

/// JavaScript that paginates the laid-out document from inside the web view.
///
/// **Pagination.** The document is one continuous column. `paginate` collects
/// "unbreakable" vertical intervals (text lines, images, table rows, the first
/// line of every block together with the block's top edge, headings together
/// with what follows them, and the padded bottom edges of boxed blocks) and picks
/// page breaks that never cut through one of them. Each break remembers the DOM
/// position where the next page starts. It then fills in the table of contents
/// page numbers.
///
/// **Export.** WebKit's PDF export cuts its output into pages of a fixed height
/// (14,400 pt). `layoutBatch` inserts invisible spacers at the remembered break
/// positions so that every page starts exactly at a multiple of that height. A
/// single export then yields one PDF page per document page, with only that
/// page's content and with fonts shared across the whole document. It also
/// reports link rectangles, anchors, and running titles in page coordinates.
/// `resetBatch` removes the spacers again, restoring the original layout.
enum PaginationScript {
    /// Resolves once web fonts and images have finished loading.
  static let waitForResources = """
    await document.fonts.ready;
    await Promise.all(Array.from(document.images).map(img => img.complete ? null :
        new Promise(resolve => { img.onload = resolve; img.onerror = resolve; })));
    return true;
    """

  static let install = #"""
    window.__pager = (() => {
      let pageHeight = 0, boxes = [], pages = [], breaks = [], spacers = [];
      const docHeight = () => Math.ceil(document.documentElement.scrollHeight);
      const topOf = el => el.getBoundingClientRect().top + window.scrollY;
      const rectOf = el => { const r = el.getBoundingClientRect(); return [r.top + window.scrollY, r.bottom + window.scrollY]; };
      const depthOf = node => { let d = 0; for (let n = node; n; n = n.parentNode) d++; return d; };
      const lowerBound = (list, y) => {
        let lo = 0, hi = list.length;
        while (lo < hi) { const mid = (lo + hi) >> 1; if (list[mid].top < y) lo = mid + 1; else hi = mid; }
        return lo;
      };
      const byTopThenOutermost = (a, b) => (a.top - b.top) || (a.depth - b.depth);

      function collectBoxes() {
        const scrollY = window.scrollY;
        let list = [];
        const add = (top, bottom, ref, depth) => { if (bottom - top > 0.5) list.push({ top, bottom, ref, depth, soft: false }); };
        // Lines of text.
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const range = document.createRange();
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!/\S/.test(node.data)) continue;
          range.selectNodeContents(node);
          for (const r of range.getClientRects()) {
            if (r.width > 0 && r.height > 0) add(r.top + scrollY, r.bottom + scrollY, node, 1e9);
          }
        }
        // Images outside running text, and table rows.
        for (const el of document.querySelectorAll('img, svg, video')) {
          if (el.closest('p, li, td, th, dt, dd, h1, h2, h3, h4, h5, h6, a')) continue;
          const [top, bottom] = rectOf(el);
          const ref = el.closest('figure') || el;
          if (bottom - top < pageHeight * 0.95) add(top, bottom, ref, depthOf(ref));
        }
        for (const el of document.querySelectorAll('tr')) {
          const [top, bottom] = rectOf(el);
          if (bottom - top < pageHeight * 0.9) add(top, bottom, el, depthOf(el));
        }
        list.sort(byTopThenOutermost);

        const extra = [];
        // Every block starts with its first line: a break before that line moves above
        // the block's top edge (including borders and padding) and inserts the spacer
        // before the block.
        const blocks = 'p, li, dt, dd, dl, ul, ol, h1, h2, h3, h4, h5, h6, pre, table, figure, hr, header, nav, ' +
                       'article, section, div, blockquote, .line';
        for (const el of document.querySelectorAll(blocks)) {
          const [top, bottom] = rectOf(el);
          if (bottom - top <= 0) continue;
          const first = lowerBound(list, top - 0.5);
          if (first < list.length && list[first].top < bottom) {
            const end = Math.min(bottom, list[first].bottom);
            if (end - top < pageHeight * 0.9) extra.push({ top, bottom: end, ref: el, depth: depthOf(el), soft: true });
          }
        }
        // Small boxed blocks are not split at all.
        for (const el of document.querySelectorAll('pre, .declaration, .aside, .step, .assessment, figure')) {
          const [top, bottom] = rectOf(el);
          if (bottom - top > 0 && bottom - top < pageHeight * 0.3) {
            extra.push({ top, bottom, ref: el, depth: depthOf(el), soft: true });
          }
        }
        // Boxed blocks keep their bottom edge with their last line.
        for (const el of document.querySelectorAll('pre, .declaration, .aside, table, .step, .assessment, figure')) {
          const [top, bottom] = rectOf(el);
          const last = lowerBound(list, bottom - 0.5) - 1;
          if (last >= 0 && list[last].top >= top) extra.push({ top: list[last].top, bottom, ref: null, depth: 2e9, soft: true });
        }
        // Headings stay with whatever follows them.
        for (const el of document.querySelectorAll('[data-keep-with-next]')) {
          const [top, bottom] = rectOf(el);
          if (bottom - top <= 0) continue;
          const next = lowerBound(list, bottom - 0.5);
          const end = next < list.length ? Math.max(bottom, list[next].bottom) : bottom;
          if (end - top < pageHeight * 0.6) extra.push({ top, bottom: end, ref: el, depth: depthOf(el), soft: true });
        }
        return list.concat(extra).sort(byTopThenOutermost);
      }

      function computePages() {
        const height = docHeight();
        const forced = Array.from(document.querySelectorAll('.page-break'))
          .map(el => ({ y: topOf(el), el })).filter(f => f.y > 0.5).sort((a, b) => a.y - b.y);
        pages = []; breaks = [null];
        let start = 0, nextForced = 0;
        while (start < height - 0.5) {
          while (nextForced < forced.length && forced[nextForced].y <= start + 0.5) nextForced++;
          const pendingForced = nextForced < forced.length ? forced[nextForced] : null;
          const limit = start + pageHeight;
          let end, next = null;
          if (pendingForced && pendingForced.y <= limit) {
            end = pendingForced.y;
            next = { y: end, ref: pendingForced.el };
          } else if (limit >= height) {
            end = height;
          } else {
            // Move the break up to the top of any interval it would cut, until stable.
            // If keep-together rules would leave too much of the page empty, only
            // avoid cutting through lines, rows, and images.
            const findBreak = includeSoft => {
              let y = limit;
              for (;;) {
                const lo = lowerBound(boxes, start + 0.5), hi = lowerBound(boxes, y);
                let best = y;
                for (let i = lo; i < hi; i++) {
                  const box = boxes[i];
                  if (box.bottom > y + 0.25 && box.top < best && (includeSoft || !box.soft)) best = box.top;
                }
                if (best >= y) return y;
                y = best;
              }
            };
            end = findBreak(true);
            if (end < limit - pageHeight * 0.3) end = Math.max(end, findBreak(false));
            if (end <= start + 0.5) {
              end = limit;  // A single interval taller than a page: cut it.
              next = { y: end, ref: null };
            } else {
              // The next page starts at the next content, skipping blank space.
              let i = lowerBound(boxes, end - 0.25);
              while (i + 1 < boxes.length && !boxes[i].ref && boxes[i + 1].top === boxes[i].top) i++;
              if (i < boxes.length && !(pendingForced && pendingForced.y <= boxes[i].top)) {
                const box = boxes[i];
                next = { y: Math.max(box.top, end), ref: box.ref, mid: (box.top + box.bottom) / 2 };
              } else if (pendingForced) {
                next = { y: pendingForced.y, ref: pendingForced.el };
              }
            }
          }
          pages.push([start, end]);
          if (!next || end >= height) break;
          breaks.push(next);
          start = next.y;
        }
      }

      function pageOf(y) {
        let lo = 0, hi = pages.length - 1;
        while (lo < hi) { const mid = (lo + hi) >> 1; if (pages[mid][1] > y + 0.25) hi = mid; else lo = mid + 1; }
        return lo;
      }

      function fillTableOfContents() {
        for (const el of document.querySelectorAll('.toc-num[data-target]')) {
          const target = document.getElementById(el.dataset.target);
          if (target) el.textContent = String(pageOf(topOf(target)) + 1);
        }
      }

      // Point links at anchors that were not rendered to their page instead
      // ("t12-foo" → "t12"), and collect every in-document link target.
      function resolveLinks() {
        const targets = new Set();
        for (const a of document.querySelectorAll('a[href^="#"]')) {
          let id = decodeURIComponent(a.getAttribute('href').slice(1));
          if (!document.getElementById(id)) {
            id = id.split('-')[0];
            if (!document.getElementById(id)) { a.removeAttribute('href'); continue; }
            a.setAttribute('href', '#' + id);
          }
          targets.add(id);
        }
        return Array.from(targets);
      }

      function paginate(height) {
        pageHeight = height;
        const linkTargets = resolveLinks();
        // Filling in page numbers must not move anything; if it does, paginate again.
        for (let attempt = 0; attempt < 3; attempt++) {
          boxes = collectBoxes();
          computePages();
          const before = Array.from(document.querySelectorAll('.page-break'), topOf);
          fillTableOfContents();
          const after = Array.from(document.querySelectorAll('.page-break'), topOf);
          if (before.every((y, i) => Math.abs(y - after[i]) < 0.25)) break;
        }
        boxes = [];
        return JSON.stringify({ height: docHeight(), pageCount: pages.length, linkTargets });
      }

      // MARK: Spacer insertion

      function blockAncestor(node) {
        for (let el = node.parentElement; el; el = el.parentElement) {
          if (!getComputedStyle(el).display.startsWith('inline')) return el;
        }
        return document.body;
      }

      // First offset in a text node whose character lies on or below the line through `mid`.
      function firstOffsetBelow(node, mid) {
        const range = document.createRange();
        const isBelow = offset => {
          for (let o = offset; o < node.length; o++) {
            range.setStart(node, o); range.setEnd(node, o + 1);
            const r = range.getBoundingClientRect();
            if (r.height > 0) return r.bottom + window.scrollY > mid;
          }
          return true;
        };
        let lo = 0, hi = node.length;
        while (lo < hi) { const m = (lo + hi) >> 1; if (isBelow(m)) hi = m; else lo = m + 1; }
        return lo;
      }

      // The DOM position where the line through `mid` starts, searching back from `node`.
      function lineStart(node, mid) {
        const walker = document.createTreeWalker(blockAncestor(node), NodeFilter.SHOW_TEXT);
        let offset = firstOffsetBelow(node, mid);
        if (offset >= node.length) {
          // The node was split by an earlier break; the line is in a following node.
          walker.currentNode = node;
          for (let next = walker.nextNode(); next; next = walker.nextNode()) {
            if (!/\S/.test(next.data)) continue;
            const o = firstOffsetBelow(next, mid);
            if (o < next.length) return { node: next, offset: o };
          }
          return null;
        }
        let position = { node, offset };
        if (offset > 0) return position;
        walker.currentNode = node;
        for (let prev = walker.previousNode(); prev; prev = walker.previousNode()) {
          if (!/\S/.test(prev.data)) continue;
          const o = firstOffsetBelow(prev, mid);
          if (o >= prev.length) break;
          position = { node: prev, offset: o };
          if (o > 0) break;
        }
        return position;
      }

      // Where to insert the spacer for a break: before a block-level element, or at the
      // start of a line inside running text. Returns null when no clean position exists.
      function insertionPoint(brk, delta, previousEnd) {
        if (!brk || !brk.ref) return null;
        if (brk.ref.nodeType === Node.TEXT_NODE) {
          if (!brk.ref.isConnected) return null;
          const position = lineStart(brk.ref, brk.mid + delta);
          if (!position) return null;
          const node = position.offset > 0 ? position.node.splitText(position.offset) : position.node;
          const measure = () => {
            const range = document.createRange();
            range.setStart(node, 0); range.setEnd(node, Math.min(1, node.length));
            return range.getBoundingClientRect().top + window.scrollY;
          };
          if (measure() < previousEnd - 0.5) return null;
          return { parent: node.parentNode, before: node, measure, row: false };
        }
        let el = brk.ref;
        // Spacers must not become flex or grid items or table cells.
        for (;;) {
          const parent = el.parentElement;
          if (!parent || parent === document.body) break;
          const display = getComputedStyle(parent).display;
          if (/flex|grid/.test(display) || el.tagName === 'TD' || el.tagName === 'TH' ||
              ['TBODY', 'THEAD', 'TFOOT'].includes(el.tagName)) { el = parent; continue; }
          break;
        }
        if (el === document.body || topOf(el) < previousEnd - 0.5) return null;
        return { parent: el.parentNode, before: el, measure: () => topOf(el), row: el.tagName === 'TR' };
      }

      function makeSpacer(row) {
        if (row) {
          const tr = document.createElement('tr');
          const td = document.createElement('td');
          td.colSpan = 1000;
          td.style.cssText = 'padding:0;border:0;background:none;height:1px';
          tr.appendChild(td);
          tr.style.cssText = 'border:0;background:none';
          tr.__sizer = td;
          return tr;
        }
        const div = document.createElement('div');
        div.style.cssText = 'display:block;height:1px;margin:0;padding:0;border:0;background:none';
        div.__sizer = div;
        return div;
      }

      function layoutBatch(first, last, chunk) {
        const origin = pages[first][0];
        const placed = [[pages[first][0], pages[first][1]]];
        let delta = 0;
        for (let i = first + 1; i <= last; i++) {
          const previous = placed[placed.length - 1];
          const point = insertionPoint(breaks[i], delta, pages[i - 1][1] + delta);
          if (point) {
            const startNow = pages[i][0] + delta;
            const target = origin + (Math.floor((previous[1] - origin) / chunk) + 1) * chunk;
            const before = point.measure();
            const spacer = makeSpacer(point.row);
            point.parent.insertBefore(spacer, point.before);
            spacers.push(spacer);
            const wanted = target - startNow;
            let height = 1 + wanted - (point.measure() - before);
            for (let attempt = 0; attempt < 3 && height >= 1; attempt++) {
              spacer.__sizer.style.height = height + 'px';
              const error = wanted - (point.measure() - before);
              if (Math.abs(error) < 0.2) break;
              height += error;
            }
            delta += point.measure() - before;
          }
          placed.push([pages[i][0] + delta, pages[i][1] + delta]);
        }

        const scrollY = window.scrollY;
        const lowerEdge = first > 0 ? pages[first - 1][1] : -Infinity;
        const upperEdge = placed[placed.length - 1][1];
        const placedPageOf = y => {
          let lo = 0, hi = placed.length - 1;
          while (lo < hi) { const mid = (lo + hi) >> 1; if (placed[mid][1] > y + 0.25) hi = mid; else lo = mid + 1; }
          return lo;
        };
        const links = [];
        const addLinks = (el, href) => {
          for (const r of el.getClientRects()) {
            const y = r.top + scrollY;
            if (r.width <= 0 || r.height <= 0 || y < lowerEdge || y >= upperEdge) continue;
            const p = placedPageOf(y);
            if (y < placed[p][0] - 0.5) continue;
            links.push({ page: first + p, x: r.left, y: y - placed[p][0], w: r.width, h: r.height, href });
          }
        };
        for (const entry of document.querySelectorAll('.toc-entry')) {
          const a = entry.querySelector('a[href]');
          if (a) addLinks(entry, a.getAttribute('href'));
        }
        for (const a of document.querySelectorAll('a[href]')) {
          if (!a.closest('.toc-entry')) addLinks(a, a.getAttribute('href'));
        }
        const targets = {};
        for (const el of document.querySelectorAll('[id]')) {
          const y = topOf(el);
          if (y < lowerEdge || y >= upperEdge) continue;
          const p = placedPageOf(y);
          targets[el.id] = [first + p, Math.max(0, y - placed[p][0])];
        }
        const marks = Array.from(document.querySelectorAll('[data-running-title]'),
                                 el => ({ y: topOf(el), title: el.dataset.runningTitle }));
        let m = -1;
        const running = placed.map(([start]) => {
          while (m + 1 < marks.length && marks[m + 1].y <= start + 1) m++;
          return m >= 0 ? marks[m].title : '';
        });
        return JSON.stringify({ origin, pages: placed, links, targets, running });
      }

      function resetBatch() {
        for (const spacer of spacers) spacer.remove();
        spacers = [];
        return true;
      }

      return { paginate, layoutBatch, resetBatch };
    })();
    true;
    """#
}
