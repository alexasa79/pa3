(() => {
  const frameDetection = window.ReedahFrameDetection;
  if (!frameDetection) { console.error("Reedah: Frame detection unavailable."); return; }
  if (!frameDetection.shouldRunInFrame()) return;
  const IN_EDITOR_FRAME = frameDetection.isEditorFrame();
  const editorNarration = window.ReedahEditorNarration;
  if (!editorNarration) { console.error("Reedah: Editor narration helpers unavailable."); return; }
  const mathNarration = window.ReedahMathNarration;
  if (!mathNarration || typeof mathNarration.readFormula !== "function") {
    console.error("Reedah: Mathematical narration helpers unavailable.");
    return;
  }

  const MIN_TEXT_LENGTH = 5;
  const MIN_HEADING_LENGTH = 3;
  const OVERLAY_OFFSET = 8;
  const SENTENCE_PAUSE_MS = 500;
  const PARAGRAPH_LEAD_IN_MS = 0;
  const PARAGRAPH_LEAD_OUT_MS = 400;
  const WORD_FOCUS_WINDOW_CHARS = 30;
  const WORD_FOCUS_EDGE_CHARS = 8;
  const WORD_FOCUS_MIN_STRENGTH = 0.02;
  const HIGHLIGHT_MODE_LIGHT = "light";
  const HIGHLIGHT_MODE_DARK = "dark";
  const DEFAULT_OL_START = 1;
  const CUSTOM_PARAGRAPH_SELECTOR = "div.mdx-p, [role='paragraph'], .reedah-blogger-paragraph";
  const TEXT_CANDIDATE_SELECTOR = `p, li, blockquote, h1, h2, h3, h4, h5, h6, ${CUSTOM_PARAGRAPH_SELECTOR}`;
  const CANDIDATE_SELECTOR = `${TEXT_CANDIDATE_SELECTOR}, ${mathNarration.ROOT_SELECTOR}`;
  const HOVER_BOX_PADDING = 32;
  const LIST_OVERLAY_MAX_GAP = 32;
  const HIDDEN_TEXT_SELECTOR =
    "[hidden], [aria-hidden='true'], .sr-only, .sr-only-focusable, .visually-hidden, .screen-reader-text";
  const state = {
    enabled: false,
    overlays: new Map(),
    activeEl: null,
    currentNativePort: null,
    currentUtteranceId: null,
    skippedSentences: new Set(),
    audioQueue: [],
    currentAudio: null,
    currentAudioUrl: null,
    currentAudioItem: null,
    nativeEnded: false,
    playbackStarted: false,
    currentSentenceRanges: [],
    currentSentenceIndex: 0,
    currentSentenceLength: 0,
    currentHighlightSpans: [],
    editorHighlight: null,
    editorHighlightProgress: 0,
    editorHighlightRange: null,
    currentHighlightEntries: [],
    currentWordEntries: [],
    highlightFrameId: null,
    playbackId: 0,
    cancelRequested: false,
    isPaused: false,
    currentHighlightTextOffset: 0,
    activeSession: null,
    prefetchSession: null,
    prefetchId: 0,
    playedHistory: [],
    pendingLeadIn: false,
    pendingLeadOut: false,
    hoveredEl: null,
    hoverScheduled: false,
    lastMouseX: null,
    lastMouseY: null,
    controls: null,
    observer: null,
    scanScheduled: false,
    positionScheduled: false
  };
  const sentence = window.ReedahSentence;
  if (!sentence || typeof sentence.buildSentenceRanges !== "function") {
    console.error("Reedah: Sentence helpers unavailable.");
    return;
  }
  const overlayGeometry = window.ReedahOverlayGeometry;
  if (!overlayGeometry || typeof overlayGeometry.computeOverlayPosition !== "function") {
    console.error("Reedah: Overlay geometry helpers unavailable.");
    return;
  }
  const hoverBounds = window.ReedahHoverBounds;
  if (!hoverBounds || typeof hoverBounds.computeHoverBounds !== "function") {
    console.error("Reedah: Hover bounds helpers unavailable.");
    return;
  }
  const highlightRanges = window.ReedahHighlightRanges;
  if (!highlightRanges || typeof highlightRanges.computeHighlightSlices !== "function") {
    console.error("Reedah: Highlight range helpers unavailable.");
    return;
  }
  const highlightProgress = window.ReedahHighlightProgress;
  if (!highlightProgress ||
    typeof highlightProgress.computeWordFocusStrength !== "function") {
    console.error("Reedah: Highlight progress helpers unavailable.");
    return;
  }
  const highlightTheme = window.ReedahHighlightTheme;
  if (!highlightTheme || typeof highlightTheme.detectHighlightMode !== "function") {
    console.error("Reedah: Highlight theme helpers unavailable.");
    return;
  }
  const orderedListNarration = window.ReedahOrderedListNarration;
  if (!orderedListNarration ||
    typeof orderedListNarration.parseIntegerAttribute !== "function" ||
    typeof orderedListNarration.resolveOrderedListItemNumber !== "function" ||
    typeof orderedListNarration.buildOrderedListNarrationPrefix !== "function") {
    console.error("Reedah: Ordered list narration helpers unavailable.");
    return;
  }
  const playbackHistory = window.ReedahPlaybackHistory;
  if (!playbackHistory ||
    typeof playbackHistory.addPlayedItem !== "function" ||
    typeof playbackHistory.shouldRevokeUrl !== "function" ||
    typeof playbackHistory.takeSkippedItem !== "function") {
    console.error("Reedah: Playback history helpers unavailable.");
    return;
  }
  const controlsNavigation = window.ReedahControlsNavigation;
  if (!controlsNavigation || typeof controlsNavigation.getAdjacentItem !== "function") {
    console.error("Reedah: Controls navigation helpers unavailable.");
    return;
  }
  const narrationText = window.ReedahNarrationText;
  if (!narrationText ||
    typeof narrationText.normalizeNarrationText !== "function") {
    console.error("Reedah: Narration text helpers unavailable.");
    return;
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === "reedah-toggle") {
      toggle();
    }
    if (message && message.type === "reedah-pause") {
      togglePause();
    }
    if (message && message.type === "reedah-state-request") {
      sendResponse({ enabled: state.enabled });
      return true;
    }
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", notifyState, { once: true });
  } else {
    notifyState();
  }

  function toggle() {
    if (state.enabled) {
      disable();
    } else {
      enable();
    }
  }

  function enable() {
    if (state.enabled) return;
    if (!document.body) return;

    state.enabled = true;
    document.documentElement.classList.add("reedah-enabled");
    notifyState();

    scanParagraphs();
    attachObservers();
  }

  function disable() {
    if (!state.enabled) return;

    state.enabled = false;
    document.documentElement.classList.remove("reedah-enabled");
    notifyState();

    stopNarration();
    detachObservers();
    removeControls();
    state.hoveredEl = null;

    for (const overlay of state.overlays.values()) {
      overlay.remove();
    }
    state.overlays.clear();
    window.ReedahBloggerParagraphs.clear(document);
  }

  function notifyState() {
    try {
      chrome.runtime.sendMessage({ type: "reedah-state", enabled: state.enabled });
    } catch (error) {
      // Ignore send errors (e.g. no background yet).
    }
  }

  function attachObservers() {
    if (!document.body) return;

    state.observer = new MutationObserver(records => {
      // Ignore Reedah's own focus/overlay classes. Editor attributes can change
      // visibility or editability without inserting/removing any nodes.
      if (records.some(record => record.type !== "attributes" || editorNarration.rootFor(record.target))) {
        // Cancellation must also work in background tabs where animation frames
        // are throttled. Positioning and range refresh can wait for the scan.
        validateEditorSessions(false);
        scheduleScan();
      }
    });

    state.observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["contenteditable", "hidden", "aria-hidden", "aria-expanded", "class"]
    });

    window.addEventListener("scroll", schedulePositionUpdate, { passive: true });
    document.addEventListener("scroll", schedulePositionUpdate, true);
    window.addEventListener("resize", schedulePositionUpdate);
    document.addEventListener("mousemove", handleMouseMove, { passive: true });
    window.addEventListener("blur", clearHover);
  }

  function detachObservers() {
    if (state.observer) {
      state.observer.disconnect();
      state.observer = null;
    }

    window.removeEventListener("scroll", schedulePositionUpdate);
    document.removeEventListener("scroll", schedulePositionUpdate, true);
    window.removeEventListener("resize", schedulePositionUpdate);
    document.removeEventListener("mousemove", handleMouseMove);
    window.removeEventListener("blur", clearHover);
  }

  function scheduleScan() {
    if (!state.enabled || state.scanScheduled) return;

    state.scanScheduled = true;
    requestAnimationFrame(() => {
      state.scanScheduled = false;
      scanParagraphs();
    });
  }

  function schedulePositionUpdate() {
    if (!state.enabled || state.positionScheduled) return;

    state.positionScheduled = true;
    requestAnimationFrame(() => {
      state.positionScheduled = false;
      if (state.lastMouseX != null && state.lastMouseY != null) {
        updateHoverFromPoint(state.lastMouseX, state.lastMouseY, { skipSchedule: true });
      }
      updatePositions();
    });
  }

  function scanParagraphs() {
    if (!state.enabled) return;

    validateEditorSessions();
    window.ReedahBloggerParagraphs.prepare(document);

    const candidates = document.querySelectorAll(CANDIDATE_SELECTOR);
    for (const el of candidates) {
      if (isCandidate(el)) {
        ensureOverlay(el);
      }
    }

    cleanupOverlays();

    if (state.overlays.size > 0) {
      ensureControls();
    }

    updatePositions();
  }

  function isCandidate(el) {
    if (!el || !el.isConnected) return false;

    const exclusions = IN_EDITOR_FRAME
      ? "nav, footer, header, aside, button, input, textarea, select, option, pre, code, script, style, .reedah-overlay, .reedah-controls"
      : "nav, footer, header, aside, form, button, input, textarea, select, option, pre, code, script, style, .reedah-overlay, .reedah-controls";
    if (el.closest(exclusions)) {
      return false;
    }
    if (el.closest(mathNarration.METADATA_SELECTOR)) return false;
    const editorRoot = editorNarration.rootFor(el);
    if (editorRoot && editorNarration.isExcluded(el, editorRoot)) return false;
    if (!IN_EDITOR_FRAME && !editorRoot && el.closest('[contenteditable]:not([contenteditable="false" i])')) return false;

    // MDX renderers and accessible custom components can use divs for paragraphs.
    // If such a wrapper contains semantic blocks, narrate those children instead.
    if (el.matches(CUSTOM_PARAGRAPH_SELECTOR) && el.querySelector(TEXT_CANDIDATE_SELECTOR)) return false;
    const isMath = el.matches(mathNarration.ROOT_SELECTOR);
    if (isMath) {
      if (el.parentElement?.closest(mathNarration.ROOT_SELECTOR)) return false;
      const paragraph = el.parentElement?.closest(TEXT_CANDIDATE_SELECTOR);
      if (paragraph && isCandidate(paragraph)) return false;
      if (!mathNarration.isVisibleRoot(el)) return false;
    }
    if (isLinkOnly(el)) return false;

    const text = editorRoot ? getFullText(el).trim() : getText(el);
    const minLength = isHeading(el) ? MIN_HEADING_LENGTH : MIN_TEXT_LENGTH;
    // SVG/CHTML formulas can have no text nodes at all. Their speech lives in
    // MathML or attributes, and is validated when narration starts.
    if (text.length < minLength && !isMath && !el.querySelector(mathNarration.ROOT_SELECTOR)) return false;

    const style = window.getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) {
      return false;
    }

    const rect = el.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return false;

    // A quotation already includes its nested paragraphs, quotes, and lists.
    // Give its text one owner so advancing cannot read those descendants again.
    for (let quote = el.parentElement?.closest("blockquote"); quote;
      quote = quote.parentElement?.closest("blockquote")) {
      if (isCandidate(quote)) return false;
    }

    if (!isListItem(el)) {
      const parentListItem = el.parentElement && el.parentElement.closest("li");
      if (parentListItem && isCandidate(parentListItem)) {
        return false;
      }
    }

    return true;
  }

  function isLinkOnly(el) {
    if (!el) return false;
    if (el.tagName === "A") return true;
    const anchors = el.querySelectorAll("a");
    if (!anchors.length) return false;

    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let node = walker.nextNode();
    while (node) {
      if (node.nodeValue && node.nodeValue.trim().length) {
        if (!node.parentElement || !node.parentElement.closest("a")) {
          return false;
        }
      }
      node = walker.nextNode();
    }

    return true;
  }

  function isHeading(el) {
    if (!el || !el.tagName) return false;
    const tag = el.tagName.toUpperCase();
    return tag === "H1" || tag === "H2" || tag === "H3" || tag === "H4" || tag === "H5" || tag === "H6";
  }

  function isListItem(el) {
    return !!el && el.tagName === "LI";
  }

  function getListContainerRect(el) {
    if (!el || !el.closest) return null;
    const list = el.closest("ul, ol");
    return list ? list.getBoundingClientRect() : null;
  }

  function getAnchorRect(el) {
    try {
      const editorRoot = editorNarration.rootFor(el);
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      let node = walker.nextNode();
      while (node) {
        if (editorRoot && editorNarration.isExcluded(node.parentElement, editorRoot)) { node = walker.nextNode(); continue; }
        const value = node.nodeValue || "";
        const run = editorRoot ? editorNarration.textRuns(value).find(run => /\S/.test(run.text)) : null;
        const index = editorRoot ? (run ? run.nodeStart + run.text.search(/\S/) : -1) : value.search(/\S/);
        if (index !== -1) {
          const range = document.createRange();
          range.setStart(node, index);
          range.setEnd(node, Math.min(index + 1, value.length));
          const rects = range.getClientRects();
          if (rects.length) {
            return rects[0];
          }
        }
        node = walker.nextNode();
      }
    } catch (error) {
      // Ignore anchor calculation errors.
    }

    return el.getBoundingClientRect();
  }

  function getText(el) {
    const raw = IN_EDITOR_FRAME ? (el.textContent || "") : (el.innerText || "");
    return raw.replace(/\s+/g, " ").trim();
  }

  function normalizeNarrationText(value) {
    return narrationText.normalizeNarrationText(value);
  }

  function shouldIncludeTextNode(targetEl, node) {
    if (!targetEl || !node) return false;
    const parent = node.parentElement;
    if (!parent) return true;
    if (parent.closest(HIDDEN_TEXT_SELECTOR)) return false;

    if (isListItem(targetEl)) {
      const ownerListItem = parent.closest("li");
      if (ownerListItem && ownerListItem !== targetEl) {
        return false;
      }
    }

    return true;
  }

  function getFullText(el) {
    // Extraction and highlighting must share the same text and UTF-16 offsets.
    return collectTextSegments(el).map(segment => segment.text).join("");
  }

  function buildNarrationPayload(el) {
    const fullText = getFullText(el);
    if (!fullText) {
      console.error("Reedah: Empty narration text.");
      return null;
    }

    const prefix = getOrderedListNarrationPrefix(el);
    if (prefix == null) return null;
    if (!prefix) {
      return {
        text: fullText,
        highlightTextOffset: 0
      };
    }

    return {
      text: `${prefix}${fullText}`,
      highlightTextOffset: prefix.length
    };
  }

  function getOrderedListNarrationPrefix(el) {
    if (!isListItem(el)) return "";
    if (!el.parentElement || el.parentElement.tagName !== "OL") return "";

    const list = el.parentElement;
    const items = [];
    for (const child of list.children) {
      if (child && child.tagName === "LI") {
        items.push(child);
      }
    }

    const targetIndex = items.indexOf(el);
    if (targetIndex === -1) {
      console.error("Reedah: Failed to find ordered list item index.");
      return null;
    }

    let start = DEFAULT_OL_START;
    if (list.hasAttribute("start")) {
      const parsedStart = orderedListNarration.parseIntegerAttribute(list.getAttribute("start"));
      if (!Number.isSafeInteger(parsedStart)) {
        console.error("Reedah: Invalid ordered list start value.");
        return null;
      }
      start = parsedStart;
    } else if (list.reversed) {
      start = items.length;
    }

    const itemValues = [];
    for (const item of items) {
      if (!item.hasAttribute("value")) {
        itemValues.push(null);
        continue;
      }

      const parsedValue = orderedListNarration.parseIntegerAttribute(item.getAttribute("value"));
      if (!Number.isSafeInteger(parsedValue)) {
        console.error("Reedah: Invalid ordered list item value.");
        return null;
      }
      itemValues.push(parsedValue);
    }

    const itemNumber = orderedListNarration.resolveOrderedListItemNumber(
      itemValues,
      start,
      list.reversed === true,
      targetIndex
    );
    if (!Number.isSafeInteger(itemNumber)) {
      console.error("Reedah: Failed to resolve ordered list item number.");
      return null;
    }

    const markerType = list.getAttribute("type") || "1";
    const prefix = orderedListNarration.buildOrderedListNarrationPrefix(itemNumber, markerType);
    if (!prefix) {
      console.error("Reedah: Failed to build ordered list narration prefix.");
      return null;
    }
    return prefix;
  }

  function findSentenceIndexForOffset(offset) {
    const ranges = state.currentSentenceRanges;
    if (!ranges.length) return -1;

    for (let i = 0; i < ranges.length; i += 1) {
      const range = ranges[i];
      if (offset >= range.start && offset < range.end) {
        return i;
      }
    }

    if (offset >= ranges[ranges.length - 1].end) {
      return ranges.length - 1;
    }

    return 0;
  }

  function updateHighlightForIndex(playbackId, index, location) {
    if (state.playbackId !== playbackId) return;
    if (!state.activeEl) return;
    if (!state.currentSentenceRanges.length) return;
    let idx = Number.isFinite(index) ? index : findSentenceIndexForOffset(location);
    if (idx < 0 || idx >= state.currentSentenceRanges.length) return;
    if (idx === state.currentSentenceIndex && (state.currentHighlightSpans.length || state.editorHighlight)) return;

    state.currentSentenceIndex = idx;
    clearHighlight();
    highlightSentence(state.activeEl, state.currentSentenceRanges[idx]);
  }

  function highlightSentence(el, sentence) {
    const segments = collectTextSegments(el, state.currentHighlightTextOffset);
    if (!segments.length) return;
    const highlightMode = highlightTheme.detectHighlightMode(el);
    if (highlightMode !== HIGHLIGHT_MODE_LIGHT && highlightMode !== HIGHLIGHT_MODE_DARK) {
      console.error("Reedah: Failed to detect highlight mode.");
      return;
    }

    const sentenceLength = sentence.end - sentence.start;
    if (!Number.isFinite(sentenceLength) || sentenceLength <= 0) {
      console.error("Reedah: Invalid sentence length for highlight progress.");
      return;
    }

    const slices = highlightRanges.computeHighlightSlices(
      segments,
      sentence.start,
      sentence.end
    );
    if (!slices.length) return;

    if (editorNarration.rootFor(el)) {
      try {
        state.editorHighlight?.clear();
        state.editorHighlight = new editorNarration.RangeHighlight(document, slices, sentence, highlightMode);
        state.currentSentenceLength = sentenceLength;
        state.editorHighlightProgress = 0;
        state.editorHighlightRange = null;
      } catch (error) {
        console.error("Reedah: Failed to highlight document editor text.", error);
        stopNarration();
      }
      return;
    }

    const spans = [];
    const entries = [];
    for (const slice of slices) {
      const span = slice.segment.math
        ? wrapMathHighlight(slice.segment.node, highlightMode)
        : wrapTextSlice(slice.segment.node, slice.startOffset, slice.endOffset, highlightMode);
      if (!span) continue;

      const sliceStart = Math.max(sentence.start, slice.segment.start) - sentence.start;
      const sliceEnd = Math.min(sentence.end, slice.segment.end) - sentence.start;
      if (sliceEnd <= sliceStart) {
        console.error("Reedah: Failed to map highlight slice for progress.");
        continue;
      }

      spans.push(span);
      entries.push({
        span,
        startOffset: sliceStart,
        endOffset: sliceEnd,
        math: slice.segment.math === true,
        ...(slice.segment.math ? { text: slice.segment.text.slice(slice.startOffset, slice.endOffset) } : {})
      });
    }

    if (!spans.length || !entries.length) {
      console.error("Reedah: Failed to create sentence highlight spans.");
      return;
    }

    for (const span of spans) {
      span.classList.remove("reedah-highlight-start", "reedah-highlight-end");
    }
    spans[0].classList.add("reedah-highlight-start");
    spans[spans.length - 1].classList.add("reedah-highlight-end");

    const wordEntries = buildWordEntries(entries, sentenceLength);
    if (!wordEntries.length) {
      console.error("Reedah: Failed to create word highlight spans.");
      const parents = new Set();
      for (const span of spans) {
        if (!span || !span.parentNode) continue;
        unwrapWordHighlights(span);
        const parent = span.parentNode;
        parents.add(parent);
        while (span.firstChild) {
          parent.insertBefore(span.firstChild, span);
        }
        parent.removeChild(span);
      }
      for (const parent of parents) {
        try {
          parent.normalize();
        } catch (error) {
          console.error("Reedah: Failed to normalize word highlight cleanup.", error);
        }
      }
      return;
    }

    state.currentHighlightSpans = spans;
    state.currentHighlightEntries = entries;
    state.currentWordEntries = wordEntries;
    state.currentSentenceLength = sentenceLength;
    applyHighlightWordFocus(0);
  }

  function buildWordEntries(entries, sentenceLength) {
    if (!Array.isArray(entries) || !entries.length) return [];
    if (!Number.isFinite(sentenceLength) || sentenceLength <= 0) return [];

    const wordRanges = collectWordRanges(entries);
    if (!wordRanges.length) return [];

    const wordEntries = [];
    for (const entry of entries) {
      appendWordEntriesForSlice(entry, wordRanges, wordEntries);
    }
    return wordEntries;
  }

  function collectWordRanges(entries) {
    const ranges = [];
    for (const entry of entries) {
      if (!entry || !entry.span) continue;
      const text = entry.text ?? entry.span.textContent ?? "";
      if (!text) continue;
      if (!Number.isSafeInteger(entry.startOffset) || !Number.isSafeInteger(entry.endOffset)) {
        console.error("Reedah: Invalid sentence offsets for word highlights.");
        return [];
      }
      const expectedLength = entry.endOffset - entry.startOffset;
      if (expectedLength <= 0 || text.length !== expectedLength) {
        console.error("Reedah: Highlight slice length mismatch.");
        return [];
      }

      const matcher = /\S+/g;
      let match = matcher.exec(text);
      while (match) {
        const start = entry.startOffset + match.index;
        const end = start + match[0].length;
        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || end <= start) {
          console.error("Reedah: Invalid word range while building highlights.");
          return [];
        }

        const previous = ranges[ranges.length - 1];
        if (previous && start < previous.end) {
          console.error("Reedah: Overlapping word ranges detected in highlight text.");
          return [];
        }
        if (previous && start === previous.end) {
          previous.end = end;
        } else {
          ranges.push({ start, end });
        }
        match = matcher.exec(text);
      }
    }
    // Tint the spaces along with their preceding word. This also covers text
    // nodes containing only whitespace between inline elements, so the active
    // phrase forms one continuous band instead of separate islands of color.
    if (ranges.length) {
      ranges[0].start = entries[0].startOffset;
      for (let index = 0; index < ranges.length; index += 1) {
        ranges[index].end = index + 1 < ranges.length
          ? ranges[index + 1].start
          : entries[entries.length - 1].endOffset;
      }
    }
    return ranges;
  }

  function appendWordEntriesForSlice(entry, wordRanges, wordEntries) {
    if (!entry || !entry.span) return;
    if (!Array.isArray(wordRanges) || !wordRanges.length) return;
    if (!Array.isArray(wordEntries)) return;

    const span = entry.span;
    const text = entry.text ?? span.textContent ?? "";
    if (!text) return;
    const entryStart = entry.startOffset;
    const entryEnd = entry.endOffset;
    if (!Number.isSafeInteger(entryStart) || !Number.isSafeInteger(entryEnd) || entryEnd <= entryStart) {
      console.error("Reedah: Invalid highlight slice offsets.");
      return;
    }
    if (text.length !== entryEnd - entryStart) {
      console.error("Reedah: Highlight slice text mismatch.");
      return;
    }

    if (entry.math) {
      // Tint the whole formula without splitting or rewriting its typesetting.
      const wordSpan = document.createElement("span");
      wordSpan.className = "reedah-highlight-word";
      while (span.firstChild) wordSpan.appendChild(span.firstChild);
      span.appendChild(wordSpan);
      wordEntries.push({ span: wordSpan, startOffset: entryStart, endOffset: entryEnd });
      return;
    }

    const pieces = [];
    for (const word of wordRanges) {
      if (word.end <= entryStart) continue;
      if (word.start >= entryEnd) break;
      const pieceStart = Math.max(word.start, entryStart);
      const pieceEnd = Math.min(word.end, entryEnd);
      if (pieceEnd <= pieceStart) continue;
      pieces.push({
        pieceStart,
        pieceEnd,
        wordStart: word.start,
        wordEnd: word.end
      });
    }
    if (!pieces.length) return;

    const fragment = document.createDocumentFragment();
    let cursor = 0;
    for (const piece of pieces) {
      const localStart = piece.pieceStart - entryStart;
      const localEnd = piece.pieceEnd - entryStart;
      if (localStart > cursor) {
        fragment.appendChild(document.createTextNode(text.slice(cursor, localStart)));
      }

      const wordSpan = document.createElement("span");
      wordSpan.className = "reedah-highlight-word";
      wordSpan.textContent = text.slice(localStart, localEnd);
      fragment.appendChild(wordSpan);
      wordEntries.push({
        span: wordSpan,
        startOffset: piece.wordStart,
        endOffset: piece.wordEnd
      });
      cursor = localEnd;
    }

    if (cursor < text.length) {
      fragment.appendChild(document.createTextNode(text.slice(cursor)));
    }

    span.textContent = "";
    span.appendChild(fragment);
  }

  function unwrapWordHighlights(container) {
    if (!container) return;
    const wordSpans = container.querySelectorAll(".reedah-highlight-word");
    for (const wordSpan of wordSpans) {
      if (!wordSpan.parentNode) continue;
      const parent = wordSpan.parentNode;
      while (wordSpan.firstChild) {
        parent.insertBefore(wordSpan.firstChild, wordSpan);
      }
      parent.removeChild(wordSpan);
    }
  }

  function clearHighlight() {
    stopHighlightWordFocusLoop();
    state.editorHighlight?.clear();
    state.editorHighlight = null;
    state.editorHighlightProgress = 0;
    state.editorHighlightRange = null;
    const spans = state.currentHighlightSpans;
    if (!spans.length) {
      state.currentHighlightSpans = [];
      state.currentHighlightEntries = [];
      state.currentWordEntries = [];
      state.currentSentenceLength = 0;
      return;
    }

    const parents = new Set();
    for (const span of spans) {
      if (!span || !span.parentNode) continue;
      unwrapWordHighlights(span);
      const parent = span.parentNode;
      parents.add(parent);
      while (span.firstChild) {
        parent.insertBefore(span.firstChild, span);
      }
      parent.removeChild(span);
    }
    for (const parent of parents) {
      try {
        parent.normalize();
      } catch (error) {
        console.error("Reedah: Failed to normalize highlighted text nodes.", error);
      }
    }
    state.currentHighlightSpans = [];
    state.currentHighlightEntries = [];
    state.currentWordEntries = [];
    state.currentSentenceLength = 0;
  }

  function resetSentenceState() {
    state.skippedSentences.clear();
    state.currentSentenceRanges = [];
    state.currentSentenceIndex = -1;
    state.currentSentenceLength = 0;
    state.currentHighlightTextOffset = 0;
    state.currentWordEntries = [];
  }

  function collectTextSegments(el, textOffset = 0) {
    if (!Number.isSafeInteger(textOffset) || textOffset < 0) {
      console.error("Reedah: Invalid highlight text offset.");
      return [];
    }
    const segments = [];
    const editorRoot = editorNarration.rootFor(el);
    let offset = textOffset;
    const append = (node, text, math, nodeStart = 0) => {
      if (!text.length) return;
      const previous = segments.at(-1);
      if (previous && (previous.math || math) && /[\p{L}\p{N}]$/u.test(previous.text) && /^[\p{L}\p{N}]/u.test(text)) {
        // Spoken operators have word boundaries even when rendered symbols do
        // not. Keep synthetic spaces on the atomic formula segment so text-node
        // offsets still address exactly the original DOM characters.
        if (math) text = ` ${text}`;
        else {
          previous.text += ' ';
          previous.end += 1;
          offset += 1;
        }
      }
      segments.push({node, text, start:offset, end:offset+text.length, math, nodeStart});
      offset += text.length;
    };
    const pending = [el];
    try {
      while (pending.length) {
        const node = pending.pop();
        if (node.nodeType === Node.TEXT_NODE) {
          if (shouldIncludeTextNode(el,node)) {
            if (editorRoot) {
              for (const run of editorNarration.textRuns(node.nodeValue || "")) append(node,run.text,false,run.nodeStart);
            } else append(node,normalizeNarrationText(node.nodeValue || ""),false);
          }
          continue;
        }
        if (node.nodeType !== Node.ELEMENT_NODE || node.matches(mathNarration.METADATA_SELECTOR)) continue;
        if (editorRoot && editorNarration.isExcluded(node,editorRoot)) continue;
        if (editorRoot && node.tagName === "BR") {
          if (!isListItem(el) || node.closest("li") === el) append(node," ",false);
          continue;
        }
        if (node.matches(mathNarration.ROOT_SELECTOR)) {
          const owner = node.closest("li");
          if (isListItem(el) && owner && owner !== el) continue;
          if (mathNarration.isVisibleRoot(node)) append(node,mathNarration.readFormula(node),true);
          // Never walk a renderer's duplicate visual, accessibility, and source
          // children. One atomic segment also keeps formula highlights intact.
          continue;
        }
        for (let i=node.childNodes.length-1;i>=0;i-=1) pending.push(node.childNodes[i]);
      }
    } catch (error) {
      console.error("Reedah: Failed to read mathematical narration.", error);
      return [];
    }
    return segments;
  }

  function createHighlightSpan(highlightMode) {
    const span = document.createElement("span");
    span.className = "reedah-highlight";
    span.classList.add(highlightMode === HIGHLIGHT_MODE_DARK
      ? "reedah-highlight-on-dark" : "reedah-highlight-on-light");
    return span;
  }

  function wrapMathHighlight(node, highlightMode) {
    if (!node?.parentNode) return null;
    try {
      const span = createHighlightSpan(highlightMode);
      node.parentNode.insertBefore(span, node);
      span.appendChild(node);
      return span;
    } catch (error) {
      console.error("Reedah: Failed to wrap formula highlight.", error);
      return null;
    }
  }

  function wrapTextSlice(node, startOffset, endOffset, highlightMode) {
    if (!node || node.nodeType !== Node.TEXT_NODE || !node.parentNode) {
      return null;
    }
    if (highlightMode !== HIGHLIGHT_MODE_LIGHT && highlightMode !== HIGHLIGHT_MODE_DARK) {
      console.error("Reedah: Invalid highlight mode.");
      return null;
    }

    const length = (node.nodeValue || "").length;
    if (length === 0) return null;

    const start = Math.max(0, Math.min(length, startOffset));
    const end = Math.max(start, Math.min(length, endOffset));
    if (end <= start) return null;

    try {
      let target = node;
      if (start > 0) {
        target = target.splitText(start);
      }
      const targetLength = (target.nodeValue || "").length;
      const sliceLength = end - start;
      if (sliceLength < targetLength) {
        target.splitText(sliceLength);
      }

      const span = createHighlightSpan(highlightMode);
      target.parentNode.insertBefore(span, target);
      span.appendChild(target);
      return span;
    } catch (error) {
      console.error("Reedah: Failed to wrap sentence highlight slice.", error);
      return null;
    }
  }

  function clearWordFocusStyles(span) {
    if (!span) return;
    span.classList.remove("reedah-highlight-word-focus");
    span.style.removeProperty("--reedah-word-focus");
  }

  function applyHighlightWordFocus(progress, range = null) {
    if (state.editorHighlight) {
      try {
        if (range) state.editorHighlight.updateRange(range.start, range.end);
        else state.editorHighlight.update(progress);
        state.editorHighlightRange = range;
        state.editorHighlightProgress = progress;
      } catch (error) {
        console.error("Reedah: Failed to update document editor highlight.", error);
        stopNarration();
      }
      return;
    }
    const entries = state.currentWordEntries;
    if (!entries.length) return;
    const sentenceLength = state.currentSentenceLength;
    if (!Number.isFinite(sentenceLength) || sentenceLength <= 0) {
      console.error("Reedah: Invalid sentence length for word focus.");
      for (const entry of entries) {
        if (!entry || !entry.span) continue;
        clearWordFocusStyles(entry.span);
      }
      return;
    }

    const clampedProgress = Math.max(0, Math.min(1, progress));
    const windowLength = Math.max(1, Math.min(WORD_FOCUS_WINDOW_CHARS, sentenceLength));
    const maxStart = Math.max(0, sentenceLength - windowLength);
    const desiredStart = (clampedProgress * sentenceLength) - (windowLength * 0.5);
    const focusStart = range ? range.start : Math.max(0, Math.min(desiredStart, maxStart));
    const focusEnd = range ? range.end : Math.min(sentenceLength, focusStart + windowLength);

    for (const entry of entries) {
      if (!entry || !entry.span) continue;
      const strength = highlightProgress.computeWordFocusStrength(
        entry.startOffset,
        entry.endOffset,
        focusStart,
        focusEnd,
        range ? 0 : WORD_FOCUS_EDGE_CHARS
      );
      if (!Number.isFinite(strength)) {
        console.error("Reedah: Invalid word focus strength.");
        clearWordFocusStyles(entry.span);
        continue;
      }
      if (strength <= WORD_FOCUS_MIN_STRENGTH) {
        clearWordFocusStyles(entry.span);
        continue;
      }

      entry.span.classList.add("reedah-highlight-word-focus");
      entry.span.style.setProperty("--reedah-word-focus", `${strength}`);
    }
  }

  function stopHighlightWordFocusLoop() {
    if (state.highlightFrameId == null) return;
    cancelAnimationFrame(state.highlightFrameId);
    state.highlightFrameId = null;
  }

  function startHighlightWordFocusLoop(playbackId, audio) {
    stopHighlightWordFocusLoop();
    if (!audio) {
      console.error("Reedah: Missing audio element for highlight progress.");
      return;
    }

    const tick = () => {
      if (state.playbackId !== playbackId) {
        stopHighlightWordFocusLoop();
        return;
      }
      if (state.currentAudio !== audio) {
        stopHighlightWordFocusLoop();
        return;
      }

      const duration = audio.duration;
      if (Number.isFinite(duration) && duration > 0) {
        if (state.currentAudioItem?.stream) applyHighlightWordFocus(0, audio.focusRange);
        else applyHighlightWordFocus(playbackHistory.pieceProgress(state.currentAudioItem, audio.currentTime / duration));
      } else {
        applyHighlightWordFocus(playbackHistory.pieceProgress(state.currentAudioItem, 0));
      }

      state.highlightFrameId = requestAnimationFrame(tick);
    };

    state.highlightFrameId = requestAnimationFrame(tick);
  }

  function ensureOverlay(el) {
    if (state.overlays.has(el)) return;

    const overlay = document.createElement("button");
    overlay.type = "button";
    overlay.className = "reedah-overlay";
    overlay.__reedahTarget = el;
    const icon = createOverlayIcon();
    overlay.appendChild(icon);
    overlay.setAttribute("aria-label", "Narrate paragraph");
    if (editorNarration.rootFor(el)) overlay.addEventListener("mousedown", event => event.preventDefault());
    overlay.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      handleOverlayClick(el);
    });

    document.body.appendChild(overlay);
    state.overlays.set(el, overlay);
  }

  function handleOverlayClick(el) {
    if (state.activeEl === el) {
      if (state.isPaused) {
        togglePause();
      } else {
        stopNarration();
      }
      return;
    }

    if (!isCandidate(el)) return;

    startNarration(el);
  }

  function startNarration(el) {
    stopNarration();

    if (editorNarration.rootFor(el) && !editorNarration.supportsHighlights(window)) {
      console.error("Reedah: CSS Custom Highlights are required to narrate this document editor.");
      return;
    }

    state.activeEl = el;
    setOverlayActive(el, true);
    ensureVisible(el, { behavior: "smooth" });

    const playbackId = ++state.playbackId;
    ReedahStreamAudio.unlock().catch(error => {
      if (state.playbackId !== playbackId) return;
      console.error("Reedah: Could not activate streaming audio.", error);
      clearActiveNarration();
    });
    state.cancelRequested = false;
    state.isPaused = false;

    const narration = buildNarrationPayload(el);
    if (!narration) {
      console.error("Reedah: Failed to build narration payload.");
      clearActiveNarration();
      return;
    }

    const sentenceRanges = sentence.buildParagraphRanges(narration.text);
    if (!sentenceRanges.length) {
      console.error("Reedah: No sentences available for narration.");
      clearActiveNarration();
      return;
    }

    const utteranceId = `${playbackId}`;
    const session = createNativeSession(narration.text, sentenceRanges, utteranceId, {
      logVoice: true,
      highlightTextOffset: narration.highlightTextOffset
    });
    if (!session) {
      console.error("Reedah: Native narration failed to start.");
      clearActiveNarration();
      return;
    }

    session.el = el;
    session.editorRoot = editorNarration.rootFor(el);
    activateSession(session, playbackId, el);
    updateControls();
  }

  function stopNarration() {
    state.cancelRequested = true;
    state.playbackId += 1;
    state.isPaused = false;
    state.pendingLeadIn = false;
    state.pendingLeadOut = false;

    stopNativeNarration({ sendStop: true });
    stopAudioPlayback();
    clearAudioQueue();
    clearPlayedHistory();
    state.nativeEnded = false;
    state.playbackStarted = false;
    clearHighlight();
    resetSentenceState();
    clearPrefetch();

    if (state.activeEl) {
      setOverlayActive(state.activeEl, false);
      state.activeEl = null;
    }
    updateControls();
  }

  function createNativeSession(text, sentenceRanges, utteranceId, options = {}) {
    const highlightTextOffset = options.highlightTextOffset == null
      ? 0
      : options.highlightTextOffset;
    if (!Number.isSafeInteger(highlightTextOffset) || highlightTextOffset < 0) {
      console.error("Reedah: Invalid native session highlight offset.");
      return null;
    }

    const port = chrome.runtime.connect({ name: "reedah-native" });
    const session = {
      port,
      streams: new Map(),
      startedAt: performance.now(),
      firstPlaybackLogged: false,
      utteranceId,
      sourceText: text,
      sentenceRanges,
      highlightTextOffset,
      audioQueue: [],
      nativeEnded: false,
      disconnecting: false,
      active: false,
      playbackId: null,
      logVoice: options.logVoice === true,
      el: null
    };

    port.onMessage.addListener((message) => {
      handleSessionMessage(session, message);
    });

    port.onDisconnect.addListener(() => {
      handleSessionDisconnect(session);
    });

    try {
      port.postMessage({ type: "start", text, utteranceId, sentenceRanges, window:options.prefetch ? 1 : 2 });
    } catch (error) {
      console.error("Reedah: Failed to start native narration.", { utteranceId, textLength: text.length, sentences: sentenceRanges.length, error });
      try {
        port.disconnect();
      } catch (disconnectError) {
        // Ignore disconnect errors after start failure.
      }
      return null;
    }

    return session;
  }

  function handleSessionMessage(session, message) {
    if (session.disconnecting) return;
    if (!message || typeof message.type !== "string") return;
    if (message.utteranceId && message.utteranceId !== session.utteranceId) return;

    if (message.type === "started") {
      if (session.logVoice && (message.voiceName || message.voiceIdentifier)) {
        console.info(
          "Reedah: Using PA3 voice:",
          message.voiceName || message.voiceIdentifier
        );
      }
      return;
    }

    if (message.type === "prepared_sentence_jobs") {
      if (!Array.isArray(message.sentenceJobs)) {
        console.error("Reedah: Invalid prepared sentence jobs payload.");
        return;
      }
      for (const job of message.sentenceJobs) {
        if (!job || typeof job !== "object") {
          console.error("Reedah: Invalid prepared sentence job.", job);
          continue;
        }
        console.info(
          "Reedah: Narration sentence sent to model:",
          job.index,
          job.location,
          job.length,
          JSON.stringify(job.text)
        );
      }
      return;
    }

    if (message.type === "audio_end") {
      try {
        const item = session.streams.get(message.index);
        if (!item) throw new Error("Unknown audio stream");
        item.stream.finish(message.chunks);
        trimStreamHistory();
      } catch (error) {
        console.error("Reedah: Invalid audio stream ending.", error);
        if (session.active) clearActiveNarration(); else discardPrefetchSession(session);
      }
      return;
    }
    if (message.type === "audio" && message.stream) {
      try {
        let item = session.streams.get(message.index);
        if (!item) {
          const stream = new ReedahStreamAudio.StreamAudio({sourceLength: message.length, estimatedDuration: message.length / 14, playbackRate: message.rate ?? 1});
          item = {url: `reedah-stream:${session.utteranceId}:${message.index}`, stream,
            index:message.index, location:message.location, rate:message.rate ?? 1,
            pieceIndex:0, pieceCount:1, progressStart:0, progressEnd:1};
          session.streams.set(message.index, item);
          stream.append(message);
          session.audioQueue.push(item);
        } else item.stream.append(message);
        if (session.active) { maybeStartPlayback(session.playbackId); updateControls(); }
      } catch (error) {
        console.error("Reedah: Invalid streaming audio.", error);
        if (session.active) clearActiveNarration(); else discardPrefetchSession(session);
      }
      return;
    }
    if (message.type === "audio") {
      enqueueAudio(session, {
        index: message.index,
        audioBase64: message.audioBase64,
        mimeType: message.mimeType,
        location: message.location,
        length: message.length,
        pieceIndex: message.pieceIndex,
        pieceCount: message.pieceCount,
        progressStart: message.progressStart,
        progressEnd: message.progressEnd,
        rate: message.rate
      });
      return;
    }

    if (message.type === "end" || message.type === "cancelled") {
      session.nativeEnded = true;
      if (session.active && session.playbackId === state.playbackId) {
        state.nativeEnded = true;
        maybeStartPlayback(session.playbackId);
        startPrefetch(session.el);
      }
      return;
    }

    if (message.type === "error") {
      if (session.active && state.cancelRequested) return;
      console.error(
        "Reedah: Native narration error.",
        message.error || "unknown_error",
        message.details || null,
        { utteranceId: session.utteranceId, role: session.active ? "active" : "prefetch" }
      );
      if (session.active) {
        clearActiveNarration();
      } else {
        discardPrefetchSession(session);
      }
    }
  }

  function handleSessionDisconnect(session) {
    if (session.disconnecting || session.nativeEnded) {
      session.disconnecting = false;
      return;
    }

    const lastError = chrome.runtime.lastError;
    const context = {
      utteranceId: session.utteranceId,
      role: session.active ? "active" : "prefetch",
      nativeEnded: session.nativeEnded,
      queuedAudio: session.audioQueue ? session.audioQueue.length : 0,
      playbackId: session.playbackId,
      lastError: lastError ? lastError.message : null
    };

    if (session.active) {
      if (state.cancelRequested) return;
      console.error("Reedah: Native narration disconnected unexpectedly.", context);
      clearActiveNarration();
      return;
    }

    console.error("Reedah: Prefetch narration disconnected unexpectedly.", context);
    discardPrefetchSession(session);
  }

  function activateSession(session, playbackId, el) {
    session.active = true;
    session.port.postMessage({type:"window", window:2});
    session.playbackId = playbackId;
    state.activeSession = session;
    state.currentNativePort = session.port;
    state.currentUtteranceId = session.utteranceId;
    state.activeEl = el;

    state.skippedSentences.clear();
    state.currentSentenceRanges = session.sentenceRanges;
    state.currentSentenceIndex = -1;
    state.currentHighlightTextOffset = session.highlightTextOffset;
    state.nativeEnded = session.nativeEnded;
    state.playbackStarted = false;
    state.isPaused = false;
    state.audioQueue = session.audioQueue;
    state.pendingLeadIn = shouldApplyParagraphDelays(el);
    state.pendingLeadOut = shouldApplyParagraphDelays(el);

    stopAudioPlayback();
    clearHighlight();
    updateControls();
  }

  function startPrefetch(el) {
    if (!state.enabled) return;
    const next = getNextCandidate(el);
    if (!next) {
      clearPrefetch();
      return;
    }

    if (state.prefetchSession && state.prefetchSession.el === next) return;

    clearPrefetch();

    if (!isCandidate(next)) return;
    if (editorNarration.rootFor(next) && !editorNarration.supportsHighlights(window)) return;

    const narration = buildNarrationPayload(next);
    if (!narration) return;

    const sentenceRanges = sentence.buildParagraphRanges(narration.text);
    if (!sentenceRanges.length) return;

    const prefetchId = ++state.prefetchId;
    const utteranceId = `prefetch-${prefetchId}`;
    const session = createNativeSession(narration.text, sentenceRanges, utteranceId, {
      highlightTextOffset: narration.highlightTextOffset, prefetch:true
    });
    if (!session) return;
    session.el = next;
    session.editorRoot = editorNarration.rootFor(next);
    state.prefetchSession = session;
  }

  function startPrefetchedNarration(el) {
    validateEditorSessions();
    const session = state.prefetchSession;
    if (!session || session.el !== el) {
      startNarration(el);
      return;
    }

    state.prefetchSession = null;
    state.cancelRequested = false;
    const playbackId = ++state.playbackId;

    setOverlayActive(el, true);
    ensureVisible(el, { behavior: "smooth" });

    activateSession(session, playbackId, el);
    maybeStartPlayback(playbackId);
    startPrefetch(el);
  }

  function editorSessionIsCurrent(session) {
    if (!session?.editorRoot) return true;
    if (!session.el?.isConnected || editorNarration.rootFor(session.el) !== session.editorRoot || !isCandidate(session.el)) return false;
    const payload = buildNarrationPayload(session.el);
    return payload?.text === session.sourceText && payload.highlightTextOffset === session.highlightTextOffset;
  }

  function validateEditorSessions(refreshHighlight = true) {
    if (!editorSessionIsCurrent(state.activeSession)) {
      console.info("Reedah: Document text changed; narration stopped. Press Play to read the updated paragraph.");
      stopNarration();
      return;
    }
    if (!editorSessionIsCurrent(state.prefetchSession)) {
      console.info("Reedah: Prefetched document text changed; discarded stale audio.");
      clearPrefetch();
    }
    // ProseMirror can replace text nodes without changing their text. Rebuild
    // ranges against the current nodes, retaining playback's focus position.
    if (refreshHighlight && state.editorHighlight && state.activeSession?.editorRoot) {
      const progress = state.editorHighlightProgress;
      const range = state.editorHighlightRange;
      highlightSentence(state.activeEl, state.currentSentenceRanges[state.currentSentenceIndex]);
      applyHighlightWordFocus(progress, range);
    }
  }

  function stopNativeNarration(options = {}) {
    const shouldSendStop = options.sendStop !== false;
    const session = state.activeSession;
    if (session && session.port) {
      session.disconnecting = true;
      session.active = false;
      if (shouldSendStop) {
        try {
          session.port.postMessage({
            type: "stop",
            utteranceId: session.utteranceId
          });
        } catch (error) {
          // Ignore postMessage errors during cleanup.
        }
      }
      try {
        session.port.disconnect();
      } catch (error) {
        // Ignore disconnect errors during cleanup.
      }
    }
    for (const item of session?.streams?.values() ?? []) item.stream.dispose();
    session?.streams?.clear();
    state.activeSession = null;
    state.currentNativePort = null;
    state.currentUtteranceId = null;
  }

  function clearPrefetch() {
    if (!state.prefetchSession) return;
    discardPrefetchSession(state.prefetchSession);
  }

  function discardPrefetchSession(session) {
    if (!session) return;

    if (state.prefetchSession === session) {
      state.prefetchSession = null;
    }

    session.active = false;
    session.disconnecting = true;
    if (session.port) {
      try {
        session.port.postMessage({
          type: "stop",
          utteranceId: session.utteranceId
        });
      } catch (error) {
        // Ignore postMessage errors during cleanup.
      }
      try {
        session.port.disconnect();
      } catch (error) {
        // Ignore disconnect errors during cleanup.
      }
    }

    clearSessionQueue(session);
    for (const item of session.streams?.values() ?? []) {
      if (!isUrlInHistory(item.url) && state.currentAudioItem !== item) item.stream.dispose();
    }
    session.streams?.clear();
  }

  function clearSessionQueue(session) {
    if (!session || !session.audioQueue) return;
    for (const item of session.audioQueue) {
      if (item.url && !isUrlInHistory(item.url)) {
        item.stream?.dispose();
        URL.revokeObjectURL(item.url);
      }
    }
    session.audioQueue.length = 0;
  }

  function enqueueAudio(session, payload) {
    if (session.active && session.playbackId !== state.playbackId) return;
    if (!payload || typeof payload.audioBase64 !== "string") {
      console.error("Reedah: Invalid audio payload from native host.", { utteranceId: session.utteranceId, role: session.active ? "active" : "prefetch", payload });
      if (session.active) {
        clearActiveNarration();
      } else {
        discardPrefetchSession(session);
      }
      return;
    }

    const url = createAudioUrl(payload.audioBase64, payload.mimeType);
    if (!url) {
      console.error("Reedah: Failed to create audio URL.", { utteranceId: session.utteranceId, mimeType: payload.mimeType, base64Length: payload.audioBase64.length });
      if (session.active) {
        clearActiveNarration();
      } else {
        discardPrefetchSession(session);
      }
      return;
    }

    const parsedIndex = Number(payload.index);
    const index = Number.isFinite(parsedIndex)
      ? parsedIndex
      : findSentenceIndexForOffset(payload.location);

    const item = {
      url,
      index,
      location: payload.location,
      rate: payload.rate ?? 1,
      pieceIndex: payload.pieceIndex,
      pieceCount: payload.pieceCount,
      progressStart: payload.progressStart,
      progressEnd: payload.progressEnd
    };
    if (session.active && state.skippedSentences.has(index)) {
      rememberPlayed(item);
      return;
    }
    session.audioQueue.push(item);

    if (session.active && session.playbackId === state.playbackId) {
      maybeStartPlayback(session.playbackId);
    }
    if (session.active && session.playbackId === state.playbackId) {
      updateControls();
    }
  }

  function maybeStartPlayback(playbackId) {
    if (state.playbackId !== playbackId) return;
    if (state.currentAudio) return;
    if (state.isPaused) return;

    if (!state.playbackStarted && state.pendingLeadIn && state.audioQueue.length > 0) {
      state.pendingLeadIn = false;
      if (PARAGRAPH_LEAD_IN_MS > 0) {
        setTimeout(() => {
          if (state.playbackId !== playbackId) return;
          if (state.isPaused) return;
          if (state.currentAudio) return;
          maybeStartPlayback(playbackId);
        }, PARAGRAPH_LEAD_IN_MS);
        return;
      }
    }

    const next = state.audioQueue.shift();
    if (!next) {
      if (state.nativeEnded && state.activeEl) {
        if (state.pendingLeadOut && PARAGRAPH_LEAD_OUT_MS > 0) {
          state.pendingLeadOut = false;
          setTimeout(() => {
            if (state.playbackId !== playbackId) return;
            if (state.isPaused) return;
            handleNarrationEnded(state.activeEl);
          }, PARAGRAPH_LEAD_OUT_MS);
          return;
        }
        handleNarrationEnded(state.activeEl);
      }
      return;
    }

    // Start with the first ready sentence; generation continues behind playback.
    playNextAudio(playbackId, next);
  }

  function playNextAudio(playbackId, next) {
    if (state.playbackId !== playbackId) return;

    if (!next) {
      next = state.audioQueue.shift();
    }
    if (!next) {
      if (state.nativeEnded && state.activeEl) {
        handleNarrationEnded(state.activeEl);
      }
      return;
    }
    if (state.isPaused) {
      state.audioQueue.unshift(next);
      return;
    }

    if (state.activeEl) {
      updateHighlightForIndex(playbackId, next.index, next.location);
    }
    if (state.playbackId !== playbackId) return;
    updateControls();

    const audio = next.stream ?? new Audio();
    if (next.stream) audio.rewind();
    const audioUrl = next.url;
    state.currentAudioItem = next;
    state.currentAudio = audio;
    state.currentAudioUrl = audioUrl;
    state.playbackStarted = true;
    audio.src = audioUrl;
    audio.playbackRate = next.rate;
    startHighlightWordFocusLoop(playbackId, audio);

    audio.onended = () => {
      if (state.playbackId !== playbackId) return;
      if (state.currentAudio !== audio) return;
      applyHighlightWordFocus(playbackHistory.pieceProgress(next, 1));
      rememberPlayed(next);
      cleanupCurrentAudio();
      if (playbackHistory.isSentenceEnd(next) && SENTENCE_PAUSE_MS > 0) {
        setTimeout(() => {
          if (state.playbackId !== playbackId) return;
          if (state.isPaused) return;
          if (state.currentAudio) return;
          maybeStartPlayback(playbackId);
        }, SENTENCE_PAUSE_MS);
        return;
      }
      maybeStartPlayback(playbackId);
    };

    audio.onerror = () => {
      if (state.playbackId !== playbackId) return;
      if (state.currentAudio !== audio) return;
      if (state.cancelRequested) return;
      const errorCode = audio.error ? audio.error.code : null;
      console.error("Reedah: Audio playback failed.", { errorCode, playbackId, src: audio.src, queueSize: state.audioQueue.length });
      cleanupCurrentAudio();
      clearActiveNarration();
    };

    audio.onwaiting = () => {
      if (state.currentAudio === audio) updateControls();
    };
    audio.onplaying = () => {
      if (state.currentAudio === audio) updateControls();
      const session = state.activeSession;
      if (state.currentAudio !== audio || !session || session.firstPlaybackLogged) return;
      session.firstPlaybackLogged = true;
      console.info("Reedah: First audio playing after", ((performance.now() - session.startedAt) / 1000).toFixed(2), "seconds", {utteranceId: session.utteranceId});
    };
    audio.play().catch((error) => {
      if (state.playbackId !== playbackId) return;
      if (state.currentAudio !== audio) return;
      if (state.isPaused && error && error.name === "AbortError") {
        return;
      }
      if (error && error.name === "AbortError") {
        return;
      }
      console.error("Reedah: Failed to start audio playback.", { error, playbackId, src: audio.src });
      cleanupCurrentAudio();
      clearActiveNarration();
    });
  }

  function createAudioUrl(base64, mimeType) {
    try {
      const bytes = base64ToUint8Array(base64);
      const blob = new Blob([bytes], { type: mimeType || "audio/wav" });
      return URL.createObjectURL(blob);
    } catch (error) {
      console.error("Reedah: Failed to decode audio payload.", { error, mimeType, base64Length: base64 ? base64.length : 0 });
      return null;
    }
  }

  function base64ToUint8Array(base64) {
    const binary = atob(base64);
    const len = binary.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  function rememberPlayed(item) {
    playbackHistory.addPlayedItem(state.playedHistory, item);
    if (item.stream && !item.consumed) {
      item.consumed = true;
      try { state.activeSession?.port?.postMessage({type:"consumed", index:item.index}); }
      catch (error) {
        console.error("Reedah: Could not release narration queue slot.", error);
        clearActiveNarration();
        return;
      }
    }
    trimStreamHistory();
  }

  function trimStreamHistory() {
    // Keep two previous sentences for replay, plus any skipped sentence still arriving.
    const history = state.playedHistory;
    for (const item of history.slice(0, Math.max(0, history.length - 2))) {
      if (!item.stream || !item.stream.finished || item === state.currentAudioItem) continue;
      item.stream.dispose();
      state.activeSession?.streams.delete(item.index);
      history.splice(history.indexOf(item), 1);
    }
  }

  function isUrlInHistory(url) {
    return state.playedHistory.some((item) => item.url === url);
  }

  function clearPlayedHistory() {
    for (const item of state.playedHistory) {
      if (item.url) {
        item.stream?.dispose();
        URL.revokeObjectURL(item.url);
      }
    }
    state.playedHistory.length = 0;
  }

  function cleanupCurrentAudio() {
    stopHighlightWordFocusLoop();
    if (!state.currentAudio) return;
    try {
      state.currentAudio.pause();
      state.currentAudio.src = "";
    } catch (error) {
      // Ignore cleanup errors.
    }
    state.currentAudio = null;
    state.currentAudioItem = null;

    if (state.currentAudioUrl) {
      if (playbackHistory.shouldRevokeUrl(
        state.currentAudioUrl,
        state.playedHistory,
        state.audioQueue
      )) {
        URL.revokeObjectURL(state.currentAudioUrl);
      }
      state.currentAudioUrl = null;
    }
  }

  function stopAudioPlayback() {
    cleanupCurrentAudio();
  }

  function clearAudioQueue() {
    if (state.activeSession) {
      clearSessionQueue(state.activeSession);
      return;
    }

    for (const item of state.audioQueue) {
      if (item.url && !isUrlInHistory(item.url)) {
        item.stream?.dispose();
        URL.revokeObjectURL(item.url);
      }
    }
    state.audioQueue.length = 0;
  }

  function setOverlayActive(el, isActive) {
    const overlay = state.overlays.get(el);
    if (!overlay) return;

    overlay.classList.toggle("reedah-overlay-active", isActive);
    overlay.classList.toggle(
      "reedah-overlay-paused",
      isActive && state.isPaused
    );
    overlay.setAttribute(
      "aria-label",
      isActive
        ? state.isPaused
          ? "Resume narration"
          : "Stop narration"
        : "Narrate paragraph"
    );
  }

  function createOverlayIcon() {
    const icon = document.createElement("span");
    icon.className = "reedah-overlay__icon";

    const play = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    play.setAttribute("viewBox", "0 0 24 24");
    play.setAttribute("aria-hidden", "true");
    play.classList.add("reedah-icon", "reedah-icon-play");
    const playPath = document.createElementNS("http://www.w3.org/2000/svg", "path");
    playPath.setAttribute("d", "M8 5 L19 12 L8 19 Z");
    play.appendChild(playPath);

    const stop = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    stop.setAttribute("viewBox", "0 0 24 24");
    stop.setAttribute("aria-hidden", "true");
    stop.classList.add("reedah-icon", "reedah-icon-stop");
    const stopRect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
    stopRect.setAttribute("x", "7");
    stopRect.setAttribute("y", "7");
    stopRect.setAttribute("width", "10");
    stopRect.setAttribute("height", "10");
    stop.appendChild(stopRect);

    const pause = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    pause.setAttribute("viewBox", "0 0 24 24");
    pause.setAttribute("aria-hidden", "true");
    pause.classList.add("reedah-icon", "reedah-icon-pause");
    const pauseLeft = document.createElementNS("http://www.w3.org/2000/svg", "rect");
    pauseLeft.setAttribute("x", "7");
    pauseLeft.setAttribute("y", "6");
    pauseLeft.setAttribute("width", "3");
    pauseLeft.setAttribute("height", "12");
    const pauseRight = document.createElementNS("http://www.w3.org/2000/svg", "rect");
    pauseRight.setAttribute("x", "14");
    pauseRight.setAttribute("y", "6");
    pauseRight.setAttribute("width", "3");
    pauseRight.setAttribute("height", "12");
    pause.appendChild(pauseLeft);
    pause.appendChild(pauseRight);

    icon.appendChild(play);
    icon.appendChild(stop);
    icon.appendChild(pause);

    return icon;
  }

  function cleanupOverlays() {
    const toRemove = [];
    for (const [el] of state.overlays) {
      if (!isCandidate(el)) {
        toRemove.push(el);
      }
    }

    for (const el of toRemove) {
      if (state.activeEl === el) {
        stopNarration();
      }
      if (state.hoveredEl === el) {
        state.hoveredEl = null;
      }
      const overlay = state.overlays.get(el);
      if (overlay) overlay.remove();
      state.overlays.delete(el);
    }
  }

  function updatePositions() {
    if (!state.enabled) return;

    for (const [el, overlay] of state.overlays) {
      if (!isCandidate(el)) continue;

      const rect = el.getBoundingClientRect();
      const anchorRect = getAnchorRect(el) || rect;
      const anchorVisible = isAnchorVisible(el, rect);

      const shouldShow = el === state.activeEl || el === state.hoveredEl;

      if (!anchorVisible || !shouldShow) {
        overlay.style.display = "none";
        continue;
      }

      overlay.style.display = "inline-flex";

      const overlayWidth = overlay.offsetWidth || 14;
      const listItem = isListItem(el);
      const listRect = listItem ? getListContainerRect(el) : null;
      const position = overlayGeometry.computeOverlayPosition({
        anchorRect,
        overlayWidth,
        overlayOffset: OVERLAY_OFFSET,
        isListItem: listItem,
        listRect,
        listOverlayMaxGap: LIST_OVERLAY_MAX_GAP,
        viewportPadding: 8
      });

      overlay.style.top = `${position.top}px`;
      overlay.style.left = `${position.left}px`;
    }
  }

  function handleNarrationEnded(el, options = {}) {
    const shouldAdvance = !options.error && !state.cancelRequested;
    const next = shouldAdvance ? getNextCandidate(el) : null;
    const usePrefetch = !!(
      next &&
      state.prefetchSession &&
      state.prefetchSession.el === next
    );

    clearActiveNarration({ keepPrefetch: usePrefetch });

    if (!state.enabled || !shouldAdvance || !next) return;

    if (usePrefetch) {
      startPrefetchedNarration(next);
      return;
    }

    if (isCandidate(next)) {
      startNarration(next);
    }
  }

  function clearActiveNarration(options = {}) {
    stopNativeNarration({ sendStop: false });
    stopAudioPlayback();
    clearAudioQueue();
    clearPlayedHistory();
    state.nativeEnded = false;
    state.playbackStarted = false;
    state.isPaused = false;
    state.pendingLeadIn = false;
    state.pendingLeadOut = false;
    clearHighlight();
    resetSentenceState();

    if (state.activeEl) {
      setOverlayActive(state.activeEl, false);
      state.activeEl = null;
    }

    if (!options.keepPrefetch) {
      clearPrefetch();
    }
    updateControls();
  }

  function handleMouseMove(event) {
    if (!state.enabled) return;
    state.lastMouseX = event.clientX;
    state.lastMouseY = event.clientY;
    if (state.hoverScheduled) return;

    state.hoverScheduled = true;
    requestAnimationFrame(() => {
      state.hoverScheduled = false;
      updateHoverFromPoint(state.lastMouseX, state.lastMouseY);
    });
  }

  function clearHover() {
    if (!state.hoveredEl) return;
    state.hoveredEl = null;
    schedulePositionUpdate();
  }

  function updateHoverFromPoint(x, y, options = {}) {
    if (state.hoveredEl) {
      const hoveredOverlay = state.overlays.get(state.hoveredEl);
      if (hoveredOverlay && isPointNearOverlay(hoveredOverlay, x, y, OVERLAY_OFFSET + 6)) {
        if (!options.skipSchedule) {
          schedulePositionUpdate();
        }
        return;
      }
    }

    const element = document.elementFromPoint(x, y);
    let candidate = null;

    if (element) {
      const overlay = element.closest ? element.closest(".reedah-overlay") : null;
      if (overlay && overlay.__reedahTarget) {
        candidate = overlay.__reedahTarget;
      } else if (element.closest) {
        candidate = element.closest(CANDIDATE_SELECTOR);
      }
    }

    if (candidate && !isCandidate(candidate)) {
      candidate = null;
    }

    if (!candidate) {
      candidate = findCandidateByHoverBox(x, y);
    }

    if (candidate === state.hoveredEl) return;
    state.hoveredEl = candidate;
    if (!options.skipSchedule) {
      schedulePositionUpdate();
    }
  }

  function findCandidateByHoverBox(x, y) {
    if (!state.overlays.size) return null;
    let best = null;
    let bestDistance = Infinity;

    for (const [el, overlay] of state.overlays) {
      if (!isCandidate(el)) continue;
      const rect = el.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) continue;

      const overlayRect = overlay && overlay.style.display !== "none"
        ? overlay.getBoundingClientRect()
        : null;
      const bounds = hoverBounds.computeHoverBounds({
        targetRect: rect,
        overlayRect,
        padding: HOVER_BOX_PADDING
      });

      if (x < bounds.left || x > bounds.right || y < bounds.top || y > bounds.bottom) continue;

      const distance = distanceToRect(x, y, rect);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = el;
      }
    }

    return best;
  }

  function distanceToRect(x, y, rect) {
    const dx = Math.max(rect.left - x, 0, x - rect.right);
    const dy = Math.max(rect.top - y, 0, y - rect.bottom);
    return Math.hypot(dx, dy);
  }

  function isPointNearOverlay(overlay, x, y, margin) {
    if (!overlay || overlay.style.display === "none") return false;
    const rect = overlay.getBoundingClientRect();
    const left = rect.left - margin;
    const right = rect.right + margin;
    const top = rect.top - margin;
    const bottom = rect.bottom + margin;
    return x >= left && x <= right && y >= top && y <= bottom;
  }

  function getCandidates() {
    return Array.from(document.querySelectorAll(CANDIDATE_SELECTOR)).filter(isCandidate);
  }

  function togglePause() {
    if (!state.activeEl) return;

    if (!state.isPaused) {
      state.isPaused = true;
      setOverlayActive(state.activeEl, true);
      if (state.currentAudio) {
        try {
          state.currentAudio.pause();
        } catch (error) {
          // Ignore pause errors.
        }
      }
      updateControls();
      return;
    }

    state.isPaused = false;
    setOverlayActive(state.activeEl, true);
    if (state.currentAudio) {
      state.currentAudio.play().catch((error) => {
        if (error && error.name === "AbortError") {
          return;
        }
        console.error("Reedah: Failed to resume audio playback.", { error, src: state.currentAudio ? state.currentAudio.src : null });
        clearActiveNarration();
      });
      updateControls();
      return;
    }

    maybeStartPlayback(state.playbackId);
    updateControls();
  }

  function getNextCandidate(current) {
    const candidates = getCandidates();
    const adjacent = controlsNavigation.getAdjacentItem(candidates, current, 1);
    if (adjacent) return adjacent;

    if (!current) return null;

    for (const candidate of candidates) {
      const position = current.compareDocumentPosition(candidate);
      if (position & Node.DOCUMENT_POSITION_FOLLOWING) {
        return candidate;
      }
    }

    return null;
  }

  function getPreviousCandidate(current) {
    const candidates = getCandidates();
    const adjacent = controlsNavigation.getAdjacentItem(candidates, current, -1);
    if (adjacent) return adjacent;

    if (!current) return null;

    for (let i = candidates.length - 1; i >= 0; i -= 1) {
      const candidate = candidates[i];
      const position = current.compareDocumentPosition(candidate);
      if (position & Node.DOCUMENT_POSITION_PRECEDING) {
        return candidate;
      }
    }

    return null;
  }

  function shouldApplyParagraphDelays(el) {
    return !!el && !isHeading(el);
  }

  function ensureControls() {
    if (state.controls && state.controls.el) return;
    const controls = createControls();
    state.controls = controls;
    document.body.appendChild(controls.el);
    updateControls();
  }

  function removeControls() {
    if (!state.controls) return;
    if (state.controls.el && state.controls.el.parentNode) {
      state.controls.el.parentNode.removeChild(state.controls.el);
    }
    state.controls = null;
  }

  function createControls() {
    const panel = document.createElement("div");
    panel.className = "reedah-controls";

    const dragHandle = document.createElement("button");
    dragHandle.type = "button";
    dragHandle.className = "reedah-controls__drag";
    dragHandle.setAttribute("aria-label", "Move controls");
    dragHandle.textContent = "⠿";
    dragHandle.setAttribute("title", "Drag to move");

    const buttons = document.createElement("div");
    buttons.className = "reedah-controls__buttons";

    const prevParagraph = document.createElement("button");
    prevParagraph.type = "button";
    prevParagraph.className = "reedah-controls__btn";
    prevParagraph.dataset.action = "prev-paragraph";
    prevParagraph.textContent = "«";
    prevParagraph.setAttribute("title", "Previous paragraph");

    const prevSentence = document.createElement("button");
    prevSentence.type = "button";
    prevSentence.className = "reedah-controls__btn";
    prevSentence.dataset.action = "prev-sentence";
    prevSentence.textContent = "‹";
    prevSentence.setAttribute("title", "Previous passage");

    const playPause = document.createElement("button");
    playPause.type = "button";
    playPause.className = "reedah-controls__btn";
    playPause.dataset.action = "playpause";
    playPause.textContent = "❚❚";
    playPause.setAttribute("title", "Play/Pause");

    const skipSentenceButton = document.createElement("button");
    skipSentenceButton.type = "button";
    skipSentenceButton.className = "reedah-controls__btn";
    skipSentenceButton.dataset.action = "skip-sentence";
    skipSentenceButton.textContent = "›";
    skipSentenceButton.setAttribute("title", "Next passage");

    const skipParagraphButton = document.createElement("button");
    skipParagraphButton.type = "button";
    skipParagraphButton.className = "reedah-controls__btn";
    skipParagraphButton.dataset.action = "skip-paragraph";
    skipParagraphButton.textContent = "»";
    skipParagraphButton.setAttribute("title", "Next paragraph");

    buttons.appendChild(prevParagraph);
    buttons.appendChild(prevSentence);
    buttons.appendChild(playPause);
    buttons.appendChild(skipSentenceButton);
    buttons.appendChild(skipParagraphButton);

    const meta = document.createElement("div");
    meta.className = "reedah-controls__meta";

    const sentence = document.createElement("div");
    sentence.className = "reedah-controls__line";

    const queue = document.createElement("div");
    queue.className = "reedah-controls__line";

    meta.appendChild(sentence);
    meta.appendChild(queue);

    panel.appendChild(dragHandle);
    panel.appendChild(buttons);
    panel.appendChild(meta);

    panel.addEventListener("click", (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement)) return;
      const button = target.closest("[data-action]");
      if (!button) return;
      const action = button.dataset.action;
      if (!action) return;

      event.preventDefault();
      event.stopPropagation();
      if (action === "playpause") {
        if (!state.activeEl) return;
        togglePause();
      } else if (action === "prev-paragraph") {
        previousParagraph();
      } else if (action === "prev-sentence") {
        playPreviousSentence();
      } else if (action === "skip-sentence") {
        skipSentence();
      } else if (action === "skip-paragraph") {
        skipParagraph();
      }
    });

    enableDrag(panel, dragHandle);

    return {
      el: panel,
      playPause,
      prevParagraph,
      prevSentence,
      skipSentence: skipSentenceButton,
      skipParagraph: skipParagraphButton,
      sentence,
      queue
    };
  }

  function updateControls() {
    if (!state.controls) return;

    const {
      playPause,
      prevParagraph,
      prevSentence,
      skipSentence,
      skipParagraph,
      sentence,
      queue
    } = state.controls;
    const active = !!state.activeEl;
    const totalSentences = state.currentSentenceRanges.length;
    const currentSentence = state.currentSentenceIndex >= 0
      ? state.currentSentenceIndex + 1
      : active && totalSentences > 0
        ? 1
        : 0;
    const queued = state.audioQueue.length;
    const hasPreviousParagraph = active && !!getPreviousCandidate(state.activeEl);
    const hasNextParagraph = active && !!getNextCandidate(state.activeEl);

    playPause.disabled = !active;
    playPause.textContent = state.isPaused ? "▶" : "❚❚";
    if (prevParagraph) {
      prevParagraph.disabled = !hasPreviousParagraph;
    }
    if (prevSentence) {
      prevSentence.disabled = !active || state.playedHistory.length === 0;
    }
    if (skipSentence) {
      skipSentence.disabled = !active;
    }
    if (skipParagraph) {
      skipParagraph.disabled = !hasNextParagraph;
    }
    const metaText = active
      ? `${state.currentAudio?.waiting ? "Buffering • " : ""}S ${currentSentence}/${totalSentences || 0} • Q ${queued}`
      : "";
    sentence.textContent = metaText;
    queue.textContent = "";
  }

  function playPreviousSentence() {
    if (!state.activeEl) return;
    if (!state.playedHistory.length) return;

    const previous = playbackHistory.rewindSentence(state.playedHistory, state.currentAudioItem, state.audioQueue);
    if (!previous) return;
    state.skippedSentences.delete(previous.index);

    if (state.currentAudio) {
      try {
        state.currentAudio.pause();
      } catch (error) {
        // Ignore pause errors.
      }
    }
    cleanupCurrentAudio();

    if (state.isPaused) {
      state.isPaused = false;
      setOverlayActive(state.activeEl, true);
    }

    playNextAudio(state.playbackId, previous);
    updateControls();
  }

  function skipSentence() {
    if (!state.activeEl) return;
    state.pendingLeadOut = false;

    const skipped = playbackHistory.takeSkippedItem(state.currentAudioItem, state.audioQueue);
    if (!skipped) {
      console.error("Reedah: No sentence available to skip.");
      return;
    }
    state.skippedSentences.add(skipped.index);
    rememberPlayed(skipped);
    while (state.audioQueue[0]?.index === skipped.index) {
      rememberPlayed(state.audioQueue.shift());
    }

    if (state.currentAudio) {
      try {
        state.currentAudio.pause();
      } catch (error) {
        // Ignore pause errors.
      }
    }
    cleanupCurrentAudio();
    if (state.isPaused) {
      state.isPaused = false;
      setOverlayActive(state.activeEl, true);
    }
    maybeStartPlayback(state.playbackId);
    updateControls();
  }

  function skipParagraph() {
    if (!state.activeEl) return;
    state.pendingLeadOut = false;
    stopNativeNarration({ sendStop: true });
    stopAudioPlayback();
    clearAudioQueue();
    clearPlayedHistory();
    state.nativeEnded = true;
    state.playbackStarted = false;
    state.isPaused = false;
    clearHighlight();
    resetSentenceState();
    handleNarrationEnded(state.activeEl);
    updateControls();
  }

  function previousParagraph() {
    if (!state.activeEl) return;
    const previous = getPreviousCandidate(state.activeEl);
    if (!previous) {
      console.error("Reedah: No previous paragraph available.");
      return;
    }
    if (!isCandidate(previous)) {
      console.error("Reedah: Previous paragraph is not narratable.");
      return;
    }
    startNarration(previous);
    updateControls();
  }

  function enableDrag(panel, handle) {
    let dragging = false;
    let offsetX = 0;
    let offsetY = 0;

    const onMove = (event) => {
      if (!dragging) return;
      const x = event.clientX - offsetX;
      const y = event.clientY - offsetY;
      const maxX = window.innerWidth - panel.offsetWidth - 8;
      const maxY = window.innerHeight - panel.offsetHeight - 8;
      const clampedX = Math.max(8, Math.min(x, maxX));
      const clampedY = Math.max(8, Math.min(y, maxY));
      panel.style.left = `${clampedX}px`;
      panel.style.top = `${clampedY}px`;
      panel.style.right = "auto";
      panel.style.bottom = "auto";
    };

    const onUp = () => {
      if (!dragging) return;
      dragging = false;
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
    };

    handle.addEventListener("mousedown", (event) => {
      event.preventDefault();
      dragging = true;
      const rect = panel.getBoundingClientRect();
      offsetX = event.clientX - rect.left;
      offsetY = event.clientY - rect.top;
      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
    });
  }

  function ensureVisible(el, options = {}) {
    if (!el) return;
    const rect = el.getBoundingClientRect();
    if (isAnchorVisible(el, rect)) return;

    el.scrollIntoView({
      block: "center",
      inline: "nearest",
      behavior: options.behavior || "smooth"
    });
  }

  function isAnchorVisible(el, rect) {
    const clip = getClippingRect(el);

    if (rect.bottom < clip.top || rect.top > clip.bottom) return false;
    if (rect.right < clip.left || rect.left > clip.right) return false;

    const anchorY = rect.top + 1;
    if (anchorY < clip.top || anchorY > clip.bottom) return false;

    let anchorX = rect.left + 1;
    if (anchorX < clip.left + 1) anchorX = clip.left + 1;
    if (anchorX > clip.right - 1) anchorX = clip.right - 1;

    if (anchorX < 0 || anchorX > window.innerWidth) return false;
    if (anchorY < 0 || anchorY > window.innerHeight) return false;

    if (IN_EDITOR_FRAME) return true;

    let elAtPoint = document.elementFromPoint(anchorX, anchorY);
    if (!elAtPoint) return false;

    if (elAtPoint.classList && elAtPoint.classList.contains("reedah-overlay")) {
      const altX = Math.min(rect.right - 1, anchorX + 8);
      if (altX !== anchorX) {
        elAtPoint = document.elementFromPoint(altX, anchorY);
      }
    }

    return !!(elAtPoint && el.contains(elAtPoint));
  }

  function getClippingRect(el) {
    let top = 0;
    let left = 0;
    let right = window.innerWidth;
    let bottom = window.innerHeight;

    let current = el.parentElement;
    while (current) {
      const style = window.getComputedStyle(current);
      const overflowY = style.overflowY;
      const overflowX = style.overflowX;
      const clipY = overflowY !== "visible";
      const clipX = overflowX !== "visible";

      if (clipY || clipX) {
        const rect = current.getBoundingClientRect();
        if (clipY) {
          top = Math.max(top, rect.top);
          bottom = Math.min(bottom, rect.bottom);
        }
        if (clipX) {
          left = Math.max(left, rect.left);
          right = Math.min(right, rect.right);
        }
      }

      current = current.parentElement;
    }

    return { top, right, bottom, left };
  }
})();
