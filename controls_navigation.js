(() => {
  function getAdjacentItem(items, current, direction) {
    if (!Array.isArray(items) || !items.length) return null;
    if (direction !== 1 && direction !== -1) return null;
    if (!current) return null;

    const index = items.indexOf(current);
    if (index < 0) return null;

    const nextIndex = index + direction;
    if (nextIndex < 0 || nextIndex >= items.length) return null;
    return items[nextIndex];
  }

  const api = { getAdjacentItem };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahControlsNavigation = api;
  }
})();
