(() => {
  function addPlayedItem(history, item) {
    if (!Array.isArray(history)) return [];
    if (!item || typeof item.url !== "string" || !item.url) {
      return history;
    }
    if (!containsUrl(history, item.url)) history.push(item);
    history.sort((a, b) => a.index - b.index || (a.pieceIndex ?? 0) - (b.pieceIndex ?? 0));
    return history;
  }

  function containsUrl(collection, url) {
    if (!Array.isArray(collection)) return false;
    return collection.some((item) => item && item.url === url);
  }

  function shouldRevokeUrl(url, history, queue) {
    if (typeof url !== "string" || !url) return false;
    if (containsUrl(history, url)) return false;
    if (containsUrl(queue, url)) return false;
    return true;
  }

  function takeSkippedItem(currentItem, queue) {
    if (currentItem && typeof currentItem.url === "string" && currentItem.url) {
      return currentItem;
    }
    if (!Array.isArray(queue) || queue.length === 0) {
      return null;
    }
    const queued = queue.shift();
    if (!queued || typeof queued.url !== "string" || !queued.url) {
      return null;
    }
    return queued;
  }

  function pieceProgress(item, fraction) {
    const start = item?.progressStart ?? 0;
    const end = item?.progressEnd ?? 1;
    return start + (end - start) * Math.max(0, Math.min(1, fraction));
  }

  function isSentenceEnd(item) {
    return item.pieceCount == null || item.pieceIndex === item.pieceCount - 1;
  }

  function rewindSentence(history, current, queue) {
    if (!history.length) return null;
    const previous = history.findLast(item => current ? item.index < current.index : true)
      ?? history.find(item => item.index === current?.index);
    if (!previous) return null;
    const start = history.findIndex(item => item.index === previous.index);
    const replay = history.splice(start);
    if (current && !replay.some(item => item.url === current.url)) replay.push(current);
    queue.unshift(...replay);
    queue.sort((a, b) => a.index - b.index || (a.pieceIndex ?? 0) - (b.pieceIndex ?? 0));
    return queue.shift();
  }

  const api = {
    pieceProgress,
    isSentenceEnd,
    rewindSentence,
    addPlayedItem,
    shouldRevokeUrl,
    takeSkippedItem
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahPlaybackHistory = api;
  }
})();
