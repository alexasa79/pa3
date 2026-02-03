(() => {
  if (window.top !== window) return;

  const MIN_TEXT_LENGTH = 20;
  const OVERLAY_OFFSET = 8;
  const AUDIO_BUFFER_TARGET = 2;
  const SENTENCE_PAUSE_MS = 1000;
  const state = {
    enabled: false,
    overlays: new Map(),
    activeEl: null,
    currentNativePort: null,
    currentUtteranceId: null,
    audioQueue: [],
    currentAudio: null,
    currentAudioUrl: null,
    nativeEnded: false,
    playbackStarted: false,
    currentSentenceRanges: [],
    currentSentenceIndex: 0,
    currentHighlightSpan: null,
    playbackId: 0,
    cancelRequested: false,
    activeSession: null,
    prefetchSession: null,
    prefetchId: 0,
    observer: null,
    scanScheduled: false,
    positionScheduled: false
  };

  chrome.runtime.onMessage.addListener((message) => {
    if (message && message.type === "reedah-toggle") {
      toggle();
    }
  });

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

    scanParagraphs();
    attachObservers();
  }

  function disable() {
    if (!state.enabled) return;

    state.enabled = false;
    document.documentElement.classList.remove("reedah-enabled");

    stopNarration();
    detachObservers();

    for (const overlay of state.overlays.values()) {
      overlay.remove();
    }
    state.overlays.clear();
  }

  function attachObservers() {
    if (!document.body) return;

    state.observer = new MutationObserver(() => {
      scheduleScan();
    });

    state.observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });

    window.addEventListener("scroll", schedulePositionUpdate, { passive: true });
    document.addEventListener("scroll", schedulePositionUpdate, true);
    window.addEventListener("resize", schedulePositionUpdate);
  }

  function detachObservers() {
    if (state.observer) {
      state.observer.disconnect();
      state.observer = null;
    }

    window.removeEventListener("scroll", schedulePositionUpdate);
    document.removeEventListener("scroll", schedulePositionUpdate, true);
    window.removeEventListener("resize", schedulePositionUpdate);
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
      updatePositions();
    });
  }

  function scanParagraphs() {
    if (!state.enabled) return;

    const candidates = document.querySelectorAll("p, li, blockquote");
    for (const el of candidates) {
      if (isCandidate(el)) {
        ensureOverlay(el);
      }
    }

    cleanupOverlays();
    updatePositions();
  }

  function isCandidate(el) {
    if (!el || !el.isConnected) return false;

    if (el.closest(
      "nav, footer, header, aside, form, button, input, textarea, select, option, pre, code, script, style, [contenteditable='true'], .reedah-overlay"
    )) {
      return false;
    }

    const text = getText(el);
    if (text.length < MIN_TEXT_LENGTH) return false;

    const style = window.getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) {
      return false;
    }

    const rect = el.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return false;

    return true;
  }

  function getText(el) {
    return (el.innerText || "").replace(/\s+/g, " ").trim();
  }

  function getFullText(el) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let text = "";
    let node = walker.nextNode();
    while (node) {
      text += node.nodeValue || "";
      node = walker.nextNode();
    }
    return text.replace(/[\r\n]/g, " ");
  }

  function buildSentenceRanges(fullText) {
    if (!fullText) return [];

    const ranges = [];
    let start = 0;
    const len = fullText.length;
    const isDelimiter = (ch) => ch === "." || ch === "!" || ch === "?";

    for (let i = 0; i < len; i += 1) {
      if (isDelimiter(fullText[i])) {
        let end = i + 1;
        while (end < len && isDelimiter(fullText[end])) {
          end += 1;
        }
        ranges.push({ start, end });
        start = end;
        i = end - 1;
      }
    }

    if (start < len) {
      ranges.push({ start, end: len });
    }

    const sentences = [];
    for (const range of ranges) {
      let sStart = range.start;
      let sEnd = range.end;
      while (sStart < sEnd && /\s/.test(fullText[sStart])) sStart += 1;
      while (sEnd > sStart && /\s/.test(fullText[sEnd - 1])) sEnd -= 1;
      if (sEnd <= sStart) continue;
      const raw = fullText.slice(sStart, sEnd);
      const text = raw.replace(/\s+/g, " ").trim();
      if (!text) continue;
      sentences.push({ start: sStart, end: sEnd });
    }

    return sentences;
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
    if (idx === state.currentSentenceIndex && state.currentHighlightSpan) return;

    state.currentSentenceIndex = idx;
    clearHighlight();
    highlightSentence(state.activeEl, state.currentSentenceRanges[idx]);
  }

  function highlightSentence(el, sentence) {
    const segments = collectTextSegments(el);
    if (!segments.length) return;
    const range = rangeFromOffsets(segments, sentence.start, sentence.end);
    if (!range || range.collapsed) return;

    try {
      const contents = range.extractContents();
      const span = document.createElement("span");
      span.className = "reedah-highlight";
      span.appendChild(contents);
      range.insertNode(span);
      state.currentHighlightSpan = span;
    } catch (error) {
      console.error("Reedah: Failed to highlight sentence.", error);
    }
  }

  function clearHighlight() {
    const span = state.currentHighlightSpan;
    if (!span || !span.parentNode) {
      state.currentHighlightSpan = null;
      return;
    }

    const parent = span.parentNode;
    while (span.firstChild) {
      parent.insertBefore(span.firstChild, span);
    }
    parent.removeChild(span);
    state.currentHighlightSpan = null;
  }

  function resetSentenceState() {
    state.currentSentenceRanges = [];
    state.currentSentenceIndex = -1;
  }

  function collectTextSegments(el) {
    const segments = [];
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let node = walker.nextNode();
    let offset = 0;

    while (node) {
      const value = node.nodeValue || "";
      if (value.length) {
        const start = offset;
        const end = offset + value.length;
        segments.push({ node, start, end });
        offset = end;
      }
      node = walker.nextNode();
    }

    return segments;
  }

  function rangeFromOffsets(segments, start, end) {
    let startNode = null;
    let startOffset = 0;
    let endNode = null;
    let endOffset = 0;

    for (const segment of segments) {
      if (!startNode && start >= segment.start && start <= segment.end) {
        startNode = segment.node;
        startOffset = Math.max(0, start - segment.start);
      }

      if (end >= segment.start && end <= segment.end) {
        endNode = segment.node;
        endOffset = Math.max(0, end - segment.start);
        break;
      }
    }

    if (!startNode || !endNode) return null;

    const range = document.createRange();
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
    return range;
  }

  function ensureOverlay(el) {
    if (state.overlays.has(el)) return;

    const overlay = document.createElement("button");
    overlay.type = "button";
    overlay.className = "reedah-overlay";
    const icon = createOverlayIcon();
    overlay.appendChild(icon);
    overlay.setAttribute("aria-label", "Narrate paragraph");
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
      stopNarration();
      return;
    }

    const text = getText(el);
    if (text.length < MIN_TEXT_LENGTH) return;

    startNarration(el);
  }

  function startNarration(el) {
    stopNarration();

    state.activeEl = el;
    setOverlayActive(el, true);
    ensureVisible(el, { behavior: "smooth" });

    const playbackId = ++state.playbackId;
    state.cancelRequested = false;

    const fullText = getFullText(el);
    const sentenceRanges = buildSentenceRanges(fullText);
    if (!sentenceRanges.length) {
      console.error("Reedah: No sentences available for narration.");
      clearActiveNarration();
      return;
    }

    const utteranceId = `${playbackId}`;
    const session = createNativeSession(fullText, sentenceRanges, utteranceId, {
      logVoice: true
    });
    if (!session) {
      console.error("Reedah: Native narration failed to start.");
      clearActiveNarration();
      return;
    }

    session.el = el;
    activateSession(session, playbackId, el);
    startPrefetch(el);
  }

  function stopNarration() {
    state.cancelRequested = true;
    state.playbackId += 1;

    stopNativeNarration({ sendStop: true });
    stopAudioPlayback();
    clearAudioQueue();
    state.nativeEnded = false;
    state.playbackStarted = false;
    clearHighlight();
    resetSentenceState();
    clearPrefetch();

    if (state.activeEl) {
      setOverlayActive(state.activeEl, false);
      state.activeEl = null;
    }
  }

  function createNativeSession(text, sentenceRanges, utteranceId, options = {}) {
    const port = chrome.runtime.connect({ name: "reedah-native" });
    const session = {
      port,
      utteranceId,
      sentenceRanges,
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
      port.postMessage({ type: "start", text, utteranceId, sentenceRanges });
    } catch (error) {
      console.error("Reedah: Failed to start native narration.", error);
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
    if (!message || typeof message.type !== "string") return;
    if (message.utteranceId && message.utteranceId !== session.utteranceId) return;

    if (message.type === "started") {
      if (session.logVoice && (message.voiceName || message.voiceIdentifier)) {
        console.info(
          "Reedah: Using macOS voice:",
          message.voiceName || message.voiceIdentifier
        );
      }
      return;
    }

    if (message.type === "audio") {
      enqueueAudio(session, {
        index: message.index,
        audioBase64: message.audioBase64,
        mimeType: message.mimeType,
        location: message.location,
        length: message.length
      });
      return;
    }

    if (message.type === "end" || message.type === "cancelled") {
      session.nativeEnded = true;
      if (session.active && session.playbackId === state.playbackId) {
        state.nativeEnded = true;
        maybeStartPlayback(session.playbackId);
      }
      return;
    }

    if (message.type === "error") {
      if (session.active && state.cancelRequested) return;
      console.error(
        "Reedah: Native narration error.",
        message.error || "unknown_error"
      );
      if (session.active) {
        clearActiveNarration();
      } else {
        discardPrefetchSession(session);
      }
    }
  }

  function handleSessionDisconnect(session) {
    if (session.disconnecting) {
      session.disconnecting = false;
      return;
    }

    if (session.active) {
      if (state.cancelRequested) return;
      console.error("Reedah: Native narration disconnected unexpectedly.");
      clearActiveNarration();
      return;
    }

    console.error("Reedah: Prefetch narration disconnected unexpectedly.");
    discardPrefetchSession(session);
  }

  function activateSession(session, playbackId, el) {
    session.active = true;
    session.playbackId = playbackId;
    state.activeSession = session;
    state.currentNativePort = session.port;
    state.currentUtteranceId = session.utteranceId;
    state.activeEl = el;

    state.currentSentenceRanges = session.sentenceRanges;
    state.currentSentenceIndex = -1;
    state.nativeEnded = session.nativeEnded;
    state.playbackStarted = false;
    state.audioQueue = session.audioQueue;

    stopAudioPlayback();
    clearHighlight();
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

    const text = getText(next);
    if (text.length < MIN_TEXT_LENGTH) return;

    const fullText = getFullText(next);
    const sentenceRanges = buildSentenceRanges(fullText);
    if (!sentenceRanges.length) return;

    const prefetchId = ++state.prefetchId;
    const utteranceId = `prefetch-${prefetchId}`;
    const session = createNativeSession(fullText, sentenceRanges, utteranceId);
    if (!session) return;
    session.el = next;
    state.prefetchSession = session;
  }

  function startPrefetchedNarration(el) {
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
  }

  function clearSessionQueue(session) {
    if (!session || !session.audioQueue) return;
    for (const item of session.audioQueue) {
      if (item.url) {
        URL.revokeObjectURL(item.url);
      }
    }
    session.audioQueue.length = 0;
  }

  function enqueueAudio(session, payload) {
    if (session.active && session.playbackId !== state.playbackId) return;
    if (!payload || typeof payload.audioBase64 !== "string") {
      console.error("Reedah: Invalid audio payload from native host.");
      if (session.active) {
        clearActiveNarration();
      } else {
        discardPrefetchSession(session);
      }
      return;
    }

    const url = createAudioUrl(payload.audioBase64, payload.mimeType);
    if (!url) {
      console.error("Reedah: Failed to create audio URL.");
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

    session.audioQueue.push({
      url,
      index,
      location: payload.location
    });

    if (session.active && session.playbackId === state.playbackId) {
      maybeStartPlayback(session.playbackId);
    }
  }

  function maybeStartPlayback(playbackId) {
    if (state.playbackId !== playbackId) return;
    if (state.currentAudio) return;

    const next = state.audioQueue.shift();
    if (!next) {
      if (state.nativeEnded && state.activeEl) {
        handleNarrationEnded(state.activeEl);
      }
      return;
    }

    if (!state.playbackStarted && !state.nativeEnded && state.audioQueue.length + 1 < AUDIO_BUFFER_TARGET) {
      state.audioQueue.unshift(next);
      return;
    }

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

    if (state.activeEl) {
      updateHighlightForIndex(playbackId, next.index, next.location);
    }

    const audio = new Audio();
    const audioUrl = next.url;
    state.currentAudio = audio;
    state.currentAudioUrl = audioUrl;
    state.playbackStarted = true;
    audio.src = audioUrl;

    audio.onended = () => {
      if (state.playbackId !== playbackId) return;
      if (state.currentAudio !== audio) return;
      cleanupCurrentAudio();
      if (SENTENCE_PAUSE_MS > 0) {
        setTimeout(() => {
          if (state.playbackId !== playbackId) return;
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
      console.error("Reedah: Audio playback failed.", errorCode);
      cleanupCurrentAudio();
      clearActiveNarration();
    };

    audio.play().catch((error) => {
      if (state.playbackId !== playbackId) return;
      if (state.currentAudio !== audio) return;
      if (error && error.name === "AbortError") {
        return;
      }
      console.error("Reedah: Failed to start audio playback.", error);
      cleanupCurrentAudio();
      clearActiveNarration();
    });
  }

  function createAudioUrl(base64, mimeType) {
    try {
      const bytes = base64ToUint8Array(base64);
      const blob = new Blob([bytes], { type: mimeType || "audio/mp4" });
      return URL.createObjectURL(blob);
    } catch (error) {
      console.error("Reedah: Failed to decode audio payload.", error);
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

  function cleanupCurrentAudio() {
    if (!state.currentAudio) return;
    try {
      state.currentAudio.pause();
      state.currentAudio.src = "";
    } catch (error) {
      // Ignore cleanup errors.
    }
    state.currentAudio = null;

    if (state.currentAudioUrl) {
      URL.revokeObjectURL(state.currentAudioUrl);
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
      if (item.url) {
        URL.revokeObjectURL(item.url);
      }
    }
    state.audioQueue.length = 0;
  }

  function setOverlayActive(el, isActive) {
    const overlay = state.overlays.get(el);
    if (!overlay) return;

    overlay.classList.toggle("reedah-overlay-active", isActive);
    overlay.setAttribute(
      "aria-label",
      isActive ? "Stop narration" : "Narrate paragraph"
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

    icon.appendChild(play);
    icon.appendChild(stop);

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
      const anchorVisible = isAnchorVisible(el, rect);

      if (!anchorVisible) {
        overlay.style.display = "none";
        continue;
      }

      overlay.style.display = "inline-flex";

      const top = rect.top;
      const overlayWidth = overlay.offsetWidth || 14;
      let left = rect.left - OVERLAY_OFFSET - overlayWidth;

      if (left < 8) {
        left = rect.right + OVERLAY_OFFSET;
      }

      overlay.style.top = `${top}px`;
      overlay.style.left = `${left}px`;
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

    const text = getText(next);
    if (text.length >= MIN_TEXT_LENGTH) {
      startNarration(next);
    }
  }

  function clearActiveNarration(options = {}) {
    stopNativeNarration({ sendStop: false });
    stopAudioPlayback();
    clearAudioQueue();
    state.nativeEnded = false;
    state.playbackStarted = false;
    clearHighlight();
    resetSentenceState();

    if (state.activeEl) {
      setOverlayActive(state.activeEl, false);
      state.activeEl = null;
    }

    if (!options.keepPrefetch) {
      clearPrefetch();
    }
  }

  function getCandidates() {
    return Array.from(document.querySelectorAll("p, li, blockquote")).filter(isCandidate);
  }

  function getNextCandidate(current) {
    const candidates = getCandidates();
    const index = candidates.indexOf(current);
    if (index >= 0 && index < candidates.length - 1) {
      return candidates[index + 1];
    }

    if (!current) return null;

    for (const candidate of candidates) {
      const position = current.compareDocumentPosition(candidate);
      if (position & Node.DOCUMENT_POSITION_FOLLOWING) {
        return candidate;
      }
    }

    return null;
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
