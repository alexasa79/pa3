(() => {
  const LIGHT_BACKGROUND_MODE = "light";
  const DARK_BACKGROUND_MODE = "dark";
  const MODE_LUMINANCE_THRESHOLD = 0.45;

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function parseColorChannel(token) {
    if (typeof token !== "string" || token.length === 0) return null;
    const trimmed = token.trim();
    if (!trimmed) return null;
    if (trimmed.endsWith("%")) {
      const percent = Number.parseFloat(trimmed.slice(0, -1));
      if (!Number.isFinite(percent)) return null;
      return clamp(Math.round((percent / 100) * 255), 0, 255);
    }
    const value = Number.parseFloat(trimmed);
    if (!Number.isFinite(value)) return null;
    return clamp(Math.round(value), 0, 255);
  }

  function parseAlphaChannel(token) {
    if (typeof token !== "string" || token.length === 0) return null;
    const trimmed = token.trim();
    if (!trimmed) return null;
    if (trimmed.endsWith("%")) {
      const percent = Number.parseFloat(trimmed.slice(0, -1));
      if (!Number.isFinite(percent)) return null;
      return clamp(percent / 100, 0, 1);
    }
    const value = Number.parseFloat(trimmed);
    if (!Number.isFinite(value)) return null;
    return clamp(value, 0, 1);
  }

  function parseColor(colorValue) {
    if (typeof colorValue !== "string") return null;
    const value = colorValue.trim().toLowerCase();
    if (!value) return null;
    if (value === "transparent") {
      return { red: 0, green: 0, blue: 0, alpha: 0 };
    }
    const colorMatch = value.match(/^rgba?\((.*)\)$/);
    if (!colorMatch) return null;

    const rawTokens = colorMatch[1].split(/[\s,/]+/).filter(Boolean);
    if (rawTokens.length !== 3 && rawTokens.length !== 4) return null;

    const red = parseColorChannel(rawTokens[0]);
    const green = parseColorChannel(rawTokens[1]);
    const blue = parseColorChannel(rawTokens[2]);
    const alpha = rawTokens.length === 4 ? parseAlphaChannel(rawTokens[3]) : 1;
    if (red == null || green == null || blue == null || alpha == null) return null;

    return { red, green, blue, alpha };
  }

  function blendColors(top, bottom) {
    const outputAlpha = top.alpha + bottom.alpha * (1 - top.alpha);
    if (outputAlpha <= 0) {
      return { red: 0, green: 0, blue: 0, alpha: 0 };
    }

    return {
      red: (top.red * top.alpha + bottom.red * bottom.alpha * (1 - top.alpha)) / outputAlpha,
      green: (top.green * top.alpha + bottom.green * bottom.alpha * (1 - top.alpha)) / outputAlpha,
      blue: (top.blue * top.alpha + bottom.blue * bottom.alpha * (1 - top.alpha)) / outputAlpha,
      alpha: outputAlpha
    };
  }

  function linearizeChannel(channel) {
    const normalized = clamp(channel / 255, 0, 1);
    if (normalized <= 0.04045) {
      return normalized / 12.92;
    }
    return ((normalized + 0.055) / 1.055) ** 2.4;
  }

  function computeRelativeLuminance(color) {
    const red = linearizeChannel(color.red);
    const green = linearizeChannel(color.green);
    const blue = linearizeChannel(color.blue);
    return red * 0.2126 + green * 0.7152 + blue * 0.0722;
  }

  function detectHighlightModeFromBackgroundColors(backgroundColors) {
    if (!Array.isArray(backgroundColors) || !backgroundColors.length) return null;

    // The page canvas is white when no opaque background is declared.
    let composite = { red: 255, green: 255, blue: 255, alpha: 1 };
    for (let i = backgroundColors.length - 1; i >= 0; i -= 1) {
      const parsed = parseColor(backgroundColors[i]);
      if (!parsed) return null;
      if (parsed.alpha <= 0) continue;
      composite = blendColors(parsed, composite);
    }

    const luminance = computeRelativeLuminance(composite);
    return luminance >= MODE_LUMINANCE_THRESHOLD ? LIGHT_BACKGROUND_MODE : DARK_BACKGROUND_MODE;
  }

  function detectHighlightMode(element) {
    if (!element) return null;
    if (typeof window === "undefined" || typeof window.getComputedStyle !== "function") {
      return null;
    }

    const backgroundColors = [];
    let current = element;
    while (current && current.nodeType === 1) {
      const style = window.getComputedStyle(current);
      if (!style || typeof style.backgroundColor !== "string") return null;
      backgroundColors.push(style.backgroundColor);
      current = current.parentElement;
    }

    return detectHighlightModeFromBackgroundColors(backgroundColors);
  }

  const api = {
    detectHighlightMode,
    detectHighlightModeFromBackgroundColors
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahHighlightTheme = api;
  }
})();
