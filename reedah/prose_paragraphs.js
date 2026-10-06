(() => {
  const SELECTOR = '.reedah-prose-paragraph';
  const ARTICLE_SELECTOR = 'article, [role="article"], .entry-content, .post-body, [itemprop~="articleBody"]';
  const ROOT_SELECTOR = `${ARTICLE_SELECTOR}, main, [role="main"], .prose`;
  const EXCLUDED = 'nav, footer, aside, form, button, input, textarea, select, option, summary, pre, script, style, template, svg, math, [hidden], [inert], [aria-hidden="true"], [role="navigation"], [role="button"], [role="menu"], [role="menubar"], [role="tablist"], [role="toolbar"], [contenteditable]:not([contenteditable="false" i])';
  const wrappers = new Set();
  const blankLineWrappers = new WeakSet();
  const marked = new Map();

  function inlineRuns(nodes, isBoundary) {
    const runs = [];
    let run = [];
    for (const node of nodes) {
      if (isBoundary(node)) {
        if (run.length) runs.push(run);
        run = [];
      } else run.push(node);
    }
    if (run.length) runs.push(run);
    return runs;
  }

  function hasReadableText(text, explicit = false) {
    text = text.trim();
    if (!/[\p{L}\p{N}]/u.test(text)) return false;
    return explicit || text.length >= 5 || /[.!?。！？]$/u.test(text) ||
      /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]{2}/u.test(text);
  }

  function blankLineRuns(nodes, isBreak, isWhitespace) {
    const runs = [];
    let run = [];
    for (let i = 0; i < nodes.length;) {
      if (!isBreak(nodes[i])) { run.push(nodes[i++]); continue; }
      const start = i;
      let breaks = 0;
      while (i < nodes.length && (isBreak(nodes[i]) || isWhitespace(nodes[i]))) {
        if (isBreak(nodes[i])) breaks += 1;
        i += 1;
      }
      if (breaks >= 2) {
        if (run.length) runs.push(run);
        run = [];
      } else run.push(...nodes.slice(start, i));
    }
    if (run.length) runs.push(run);
    return runs;
  }

  function prepareBlankLines(document, mathSelector) {
    for (const root of document.querySelectorAll('p, [role="paragraph"], div.mdx-p')) {
      if (root.closest(EXCLUDED) || root.closest(SELECTOR) || root.querySelector(SELECTOR) ||
          root.closest(mathSelector) || excludedHeader(root) || isHidden(root)) continue;
      let container = root;
      // LinkedIn wraps a complete post in one P > SPAN, with BR pairs rather
      // than paragraph elements. Descend only through a wrapper that owns all
      // the text, so surrounding prose cannot be lost when the parent is skipped.
      while (true) {
        const meaningful = [...container.childNodes].filter(node => node.nodeType !== 3 || node.nodeValue.trim());
        if (meaningful.length !== 1 || meaningful[0].nodeType !== 1 ||
            !meaningful[0].matches('span') || meaningful[0].matches(mathSelector)) break;
        container = meaningful[0];
      }
      const isBreak = node => node.nodeType === 1 && node.tagName === 'BR';
      const runs = blankLineRuns([...container.childNodes], isBreak,
        node => node.nodeType === 3 && !node.nodeValue.trim());
      const readable = runs.filter(run => hasReadableText(run.map(node=>node.textContent).join(''), true));
      if (readable.length < 2) continue;
      for (const run of readable) {
        const paragraph = document.createElement('span');
        paragraph.className = SELECTOR.slice(1);
        paragraph.setAttribute('role', 'paragraph');
        container.insertBefore(paragraph, run[0]);
        for (const node of run) paragraph.appendChild(node);
        wrappers.add(paragraph);
        blankLineWrappers.add(paragraph);
      }
    }
  }

  function isLinkedProse(text) {
    text = text.replace(/\s+/g, ' ').trim();
    return text.length >= 40 && /[.!?。！？]["'”’)]*$/u.test(text);
  }

  function isHidden(el) {
    if (el.closest('[hidden], [inert], [aria-hidden="true"], .sr-only, .sr-only-focusable, .visually-hidden, .screen-reader-text')) return true;
    if (el.closest('details:not([open])')) return true;
    for (let node = el; node; node = node.parentElement) {
      const style = node.ownerDocument.defaultView.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' ||
          style.contentVisibility === 'hidden' || Number(style.opacity) === 0) return true;
    }
    return false;
  }

  function excludedHeader(el) {
    const header = el.closest('header');
    return !!header && !header.closest(ARTICLE_SELECTOR);
  }

  function isRelevantMutation(record) {
    if (record.type !== 'attributes') return true;
    if (record.target.closest('.reedah-overlay, .reedah-controls, .reedah-highlight')) return false;
    if (record.attributeName !== 'class') return true;
    const pageClasses = value => (value || '').split(/\s+/).filter(name => name && !name.startsWith('reedah-')).sort().join(' ');
    return pageClasses(record.oldValue) !== pageClasses(record.target.getAttribute('class'));
  }

  function unmark(el, hadClass) {
    el.classList.remove(SELECTOR.slice(1));
    if (!hadClass && !el.getAttribute('class')) el.removeAttribute('class');
    marked.delete(el);
  }

  function prepare(document, semanticSelector, customSelector, mathSelector) {
    const isBoundary = node => {
      if (node.nodeType === 3) return false;
      if (node.nodeType !== 1) return true;
      if (node.matches(`br, ${EXCLUDED}, ${semanticSelector}`)) return true;
      if (node.querySelector(semanticSelector)) return true;
      const display = document.defaultView.getComputedStyle(node).display;
      return display !== 'inline' && display !== 'contents';
    };
    // Pages can turn a leaf block into a mixed container after activation.
    // Release its previous ownership so new children and old bare text both scan.
    for (const [el, hadClass] of marked) {
      if (!el.isConnected || [...el.childNodes].some(isBoundary)) unmark(el, hadClass);
    }
    for (const wrapper of wrappers) {
      if (!wrapper.isConnected || [...wrapper.childNodes].some(node =>
        !(blankLineWrappers.has(wrapper) && node.nodeType === 1 && node.tagName === 'BR') && isBoundary(node))) {
        wrapper.replaceWith(...wrapper.childNodes);
        wrappers.delete(wrapper);
      }
    }
    prepareBlankLines(document, mathSelector);
    // Explicit article/main landmarks contain prose represented by many HTML
    // shapes. Scan each container once; do not treat arbitrary page chrome as prose.
    const containers = new Set();
    for (const root of document.querySelectorAll(`${ROOT_SELECTOR}, ${customSelector}`)) {
      containers.add(root);
      for (const el of root.querySelectorAll('*')) containers.add(el);
    }
    for (const container of containers) {
      if (container.namespaceURI !== 'http://www.w3.org/1999/xhtml' ||
          container.closest(EXCLUDED) || excludedHeader(container) ||
          container.closest(SELECTOR) || container.closest(mathSelector)) continue;
      const owner = container.closest(semanticSelector);
      // A custom paragraph wrapping semantic blocks still owns its bare prose.
      // Existing paragraphs/lists/quotes retain responsibility for their contents.
      if (owner && !(owner.matches(customSelector) && owner.querySelector(semanticSelector))) continue;
      const display = document.defaultView.getComputedStyle(container).display;
      if (!['block', 'flow-root', 'flex', 'grid', 'table-cell', 'contents', 'inline-block'].includes(display)) continue;
      if (isHidden(container)) continue;
      const nodes = [...container.childNodes];
      const runs = inlineRuns(nodes, isBoundary);
      for (const run of runs) {
        const text = run.map(node => node.textContent).join('');
        if (!hasReadableText(text)) continue;
        if (run.length === nodes.length) {
          // A complete leaf block already has ideal geometry. Marking it leaves
          // flex/grid children, selectors and inherited text layout untouched.
          marked.set(container, container.hasAttribute('class'));
          container.classList.add(SELECTOR.slice(1));
        } else {
          const paragraph = document.createElement('span');
          paragraph.className = SELECTOR.slice(1);
          container.insertBefore(paragraph, run[0]);
          for (const node of run) paragraph.appendChild(node);
          wrappers.add(paragraph);
        }
      }
    }
  }

  function clear() {
    for (const paragraph of wrappers) paragraph.replaceWith(...paragraph.childNodes);
    wrappers.clear();
    for (const [el, hadClass] of marked) unmark(el, hadClass);
    marked.clear();
  }

  const api = {SELECTOR, ROOT_SELECTOR, ARTICLE_SELECTOR, inlineRuns, blankLineRuns, hasReadableText, isLinkedProse,
    isHidden, excludedHeader, isRelevantMutation, prepare, clear};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.ReedahProseParagraphs = api;
})();
