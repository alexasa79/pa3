(() => {
  const SELECTOR = '.reedah-blogger-paragraph';
  const ROOT_SELECTOR = '.post-body.entry-content';
  const EXCLUDED = 'p, li, blockquote, h1, h2, h3, h4, h5, h6, nav, header, footer, aside, form, button, input, textarea, select, pre, code, script, style, [hidden], [aria-hidden="true"], [contenteditable]:not([contenteditable="false" i])';

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

  function prepare(document) {
    for (const root of document.querySelectorAll(ROOT_SELECTOR)) {
      // Blogger's older editor stores paragraphs as bare text and inline nodes
      // separated by BRs or DIVs. Give each run an element for existing controls
      // and highlighting, preserving the original nodes and line breaks.
      for (const container of [root, ...root.querySelectorAll('div, td')]) {
        if (container.closest(EXCLUDED) || container.closest(SELECTOR)) continue;
        const runs = inlineRuns([...container.childNodes], node => {
          if (node.nodeType === 3) return false;
          if (node.nodeType !== 1) return true;
          if (node.matches(`br, ${EXCLUDED}, ${SELECTOR}`)) return true;
          if (node.querySelector(`div, table, ${EXCLUDED}, ${SELECTOR}`)) return true;
          const display = document.defaultView.getComputedStyle(node).display;
          return display !== 'inline' && display !== 'contents';
        });
        for (const run of runs) {
          const text = run.map(node => node.textContent).join('');
          if (text.trim().length < 5 || !/[\p{L}\p{N}]/u.test(text)) continue;
          const paragraph = document.createElement('span');
          paragraph.className = SELECTOR.slice(1);
          container.insertBefore(paragraph, run[0]);
          for (const node of run) paragraph.appendChild(node);
        }
      }
    }
  }

  function clear(document) {
    for (const paragraph of document.querySelectorAll(SELECTOR)) {
      paragraph.replaceWith(...paragraph.childNodes);
    }
  }

  const api = {SELECTOR, inlineRuns, prepare, clear};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.ReedahBloggerParagraphs = api;
})();
