(() => {
  if (window.top !== window) return;

  const MIN_TEXT_LENGTH = 20;
  const OVERLAY_OFFSET = 8;
  const state = {
    enabled: false,
    overlays: new Map(),
    activeEl: null,
    currentAudio: null,
    currentAudioUrl: null,
    playbackId: 0,
    cancelRequested: false,
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

  function ensureOverlay(el) {
    if (state.overlays.has(el)) return;

    const overlay = document.createElement("button");
    overlay.type = "button";
    overlay.className = "reedah-overlay";
    overlay.textContent = "▶";
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

    startNarration(el, text);
  }

  function startNarration(el, text) {
    stopNarration();

    state.activeEl = el;
    setOverlayActive(el, true);
    ensureVisible(el, { behavior: "smooth" });

    const playbackId = ++state.playbackId;
    state.cancelRequested = false;

    startElevenLabsNarration(el, text, playbackId).then((started) => {
      if (!started && state.playbackId === playbackId) {
        console.error("Reedah: ElevenLabs narration failed to start.");
        clearActiveNarration();
      }
    });
  }

  function stopNarration() {
    state.cancelRequested = true;
    state.playbackId += 1;

    stopAudioPlayback();

    if (state.activeEl) {
      setOverlayActive(state.activeEl, false);
      state.activeEl = null;
    }
  }

  function startElevenLabsNarration(el, text, playbackId) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: "reedah-narrate", text }, (response) => {
          if (state.playbackId !== playbackId) return resolve(true);

          if (chrome.runtime.lastError) {
            console.error("Reedah: ElevenLabs request failed.", chrome.runtime.lastError);
            return resolve(false);
          }

          if (!response || !response.ok) {
            if (response && response.error) {
              console.error("Reedah: ElevenLabs unavailable.", response.error);
            }
            return resolve(false);
          }

          if (response.voiceId) {
            console.info("Reedah: Using ElevenLabs voice:", response.voiceId);
          }

          if (!response.audioBase64 || typeof response.audioBase64 !== "string") {
            console.error("Reedah: Invalid ElevenLabs audio payload.", {
              type: typeof response.audioBase64
            });
            return resolve(false);
          }

          const audioBuffer = base64ToArrayBuffer(response.audioBase64);
          const blob = new Blob([audioBuffer], { type: response.mimeType || "audio/mpeg" });
          const url = URL.createObjectURL(blob);
          const audio = new Audio(url);

          state.currentAudio = audio;
          state.currentAudioUrl = url;

          audio.onended = () => {
            if (state.playbackId !== playbackId) return;
            handleNarrationEnded(el);
          };

          audio.onerror = () => {
            if (state.playbackId !== playbackId) return;
            handleNarrationEnded(el, { error: true });
          };

          audio
            .play()
            .then(() => resolve(true))
            .catch((error) => {
              console.error("Reedah: Failed to play ElevenLabs audio.", error);
              stopAudioPlayback();
              resolve(false);
            });
        });
      } catch (error) {
        console.error("Reedah: ElevenLabs message failed.", error);
        resolve(false);
      }
    });
  }

  function base64ToArrayBuffer(base64) {
    const binary = atob(base64);
    const len = binary.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  function stopAudioPlayback() {
    if (state.currentAudio) {
      try {
        state.currentAudio.pause();
        state.currentAudio.src = "";
      } catch (error) {
        // Ignore cleanup errors.
      }
      state.currentAudio = null;
    }

    if (state.currentAudioUrl) {
      URL.revokeObjectURL(state.currentAudioUrl);
      state.currentAudioUrl = null;
    }
  }

  function setOverlayActive(el, isActive) {
    const overlay = state.overlays.get(el);
    if (!overlay) return;

    overlay.textContent = isActive ? "■" : "▶";
    overlay.classList.toggle("reedah-overlay-active", isActive);
    overlay.setAttribute(
      "aria-label",
      isActive ? "Stop narration" : "Narrate paragraph"
    );
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
    clearActiveNarration();

    if (!state.enabled || !shouldAdvance) return;

    const next = getNextCandidate(el);
    if (next) {
      const text = getText(next);
      if (text.length >= MIN_TEXT_LENGTH) {
        startNarration(next, text);
        return;
      }
    }
  }

  function clearActiveNarration() {
    stopAudioPlayback();

    if (state.activeEl) {
      setOverlayActive(state.activeEl, false);
      state.activeEl = null;
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
