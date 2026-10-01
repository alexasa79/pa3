(() => {
  const ROOT = '#AkMainContent #ak-editor-textarea.ProseMirror';
  const UI = '.ProseMirror-widget, .telepointer, .pm-placeholder, .pm-placeholder__text, .ak-editor-expand__title-container, .ak-editor-expand__content--collapsed, .pm-breakout-resize-handle-container, .cm-editor, button, [role="button"], input, textarea, select';

  function isConfluenceLocation(location) {
    return !!location && /^[^.]+\.atlassian\.net$/i.test(location.hostname || '') &&
      /^\/wiki\/spaces\/[^/]+\/pages\/[^/]+(?:\/|$)/.test(location.pathname || '');
  }

  function rootFor(el, location = el?.ownerDocument?.location) {
    if (!el?.closest || !isConfluenceLocation(location)) return null;
    return el.closest(ROOT);
  }

  function isExcluded(el, root) {
    if (!root || !root.contains(el)) return false;
    if (el.closest(UI)) return true;
    // Nested text inputs belong to their own editor, even when embedded in the
    // page. contenteditable=false can also mark real inline cards or formulas.
    for (let node = el; node; node = node.parentElement) {
      const editable = node.getAttribute('contenteditable');
      if (node !== root && editable != null && editable.toLowerCase() !== 'false') return true;
      if (node.hidden || node.getAttribute('aria-hidden') === 'true') return true;
      const style = node.ownerDocument.defaultView.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return true;
      if (node === root) break;
    }
    return false;
  }

  // Preserve UTF-16 offsets while omitting invisible collaboration cursor marks.
  // Each retained run still points at the original, unsplit DOM text node.
  function textRuns(text) {
    const runs = [];
    // Confluence puts standalone joiners beside remote cursors. Keep joiners
    // within actual words/emoji, such as the woman-technologist emoji.
    const markers = /[\u200b\ufeff]|(?<!\S)\u200d+|\u200d+(?!\S)/gu;
    let cursor = 0;
    for (const match of text.matchAll(markers)) {
      if (match.index > cursor) runs.push({text:text.slice(cursor,match.index).replace(/[\r\n]/g,' '), nodeStart:cursor});
      cursor = match.index + match[0].length;
    }
    if (cursor < text.length) runs.push({text:text.slice(cursor).replace(/[\r\n]/g,' '),nodeStart:cursor});
    return runs;
  }

  function focusWords(text) {
    const words = [...text.matchAll(/\S+/gu)].map(match => ({start:match.index, end:match.index + match[0].length}));
    if (words.length) {
      words[0].start = 0;
      for (let i = 0; i < words.length; i++) words[i].end = words[i + 1]?.start ?? text.length;
    }
    return words;
  }

  function supportsHighlights(win) {
    return typeof win?.Highlight === 'function' && typeof win.CSS?.highlights?.set === 'function';
  }

  class RangeHighlight {
    constructor(doc, slices, sentence, mode) {
      const win = doc.defaultView;
      if (!supportsHighlights(win)) throw new Error('CSS Custom Highlights are unavailable for this document editor.');
      if (!['light','dark'].includes(mode)) throw new Error('Invalid editor highlight theme.');
      this.doc = doc;
      this.registry = win.CSS.highlights;
      this.sentenceName = `reedah-editor-sentence-${mode}`;
      this.focusName = `reedah-editor-focus-${mode}`;
      this.length = sentence.end - sentence.start;
      this.entries = slices.map(({segment, startOffset, endOffset}) => ({
        segment, startOffset, endOffset,
        start:segment.start + startOffset - sentence.start,
        end:segment.start + endOffset - sentence.start
      }));
      const first = this.entries[0];
      if (!first) throw new Error('No editor text available to highlight.');
      const text = ' '.repeat(first.start) + this.entries.map(e => e.segment.text.slice(e.startOffset,e.endOffset)).join('');
      this.words = focusWords(text);
      this.sentenceHighlight = new win.Highlight(...this.ranges(0, this.length));
      this.focusHighlight = new win.Highlight();
      this.focusHighlight.priority = 1;
      this.registry.set(this.sentenceName, this.sentenceHighlight);
      this.registry.set(this.focusName, this.focusHighlight);
      this.update(0);
    }

    ranges(start, end) {
      const ranges = [];
      for (const entry of this.entries) {
        const from = Math.max(start, entry.start), to = Math.min(end, entry.end);
        if (to <= from) continue;
        const range = this.doc.createRange(), {segment} = entry;
        if (segment.math || segment.node.nodeType !== 3) range.selectNode(segment.node);
        else {
          const offset = (segment.nodeStart || 0) + entry.startOffset;
          range.setStart(segment.node, offset + from - entry.start);
          range.setEnd(segment.node, offset + to - entry.start);
        }
        ranges.push(range);
      }
      return ranges;
    }

    update(progress) {
      if (!Number.isFinite(progress)) throw new Error('Invalid editor highlight progress.');
      const width = Math.min(30, this.length);
      const start = Math.max(0, Math.min(Math.max(0,Math.min(1,progress)) * this.length - width / 2, this.length - width));
      const words = this.words.filter(word => word.end > start && word.start < start + width);
      const key = words.length ? `${words[0].start}:${words.at(-1).end}` : '';
      if (key === this.focusKey) return;
      this.focusKey = key;
      this.focusHighlight.clear();
      if (words.length) for (const range of this.ranges(words[0].start, words.at(-1).end)) this.focusHighlight.add(range);
    }

    clear() {
      // Do not disturb highlights belonging to Confluence or another extension.
      if (this.registry.get(this.sentenceName) === this.sentenceHighlight) this.registry.delete(this.sentenceName);
      if (this.registry.get(this.focusName) === this.focusHighlight) this.registry.delete(this.focusName);
    }
  }

  const api = {isConfluenceLocation, rootFor, isExcluded, textRuns, focusWords, supportsHighlights, RangeHighlight};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.ReedahEditorNarration = api;
})();
