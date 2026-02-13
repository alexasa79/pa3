(() => {
  function addPlayedItem(history, item) {
    if (!Array.isArray(history)) return [];
    if (!item || typeof item.url !== "string" || !item.url) {
      return history;
    }
    history.push(item);
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

  const api = {
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
