(() => {
  const LIGHT_BACKGROUND_MODE = "light";
  const DARK_BACKGROUND_MODE = "dark";
  const MODE_LUMINANCE_THRESHOLD = 0.45;

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  let colorContext;

  function resolveBrowserColor(value) {
    if (typeof value !== "string" || !CSS.supports("color", value)) {
      throw new Error(`Invalid computed background color: ${value}`);
    }
    if (!colorContext) {
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = 1;
      colorContext = canvas.getContext("2d", {colorSpace: "srgb", willReadFrequently: true});
      if (!colorContext) throw new Error("Color conversion canvas unavailable");
    }
    // Let Chrome interpret all supported CSS color spaces instead of parsing
    // getComputedStyle strings, which can preserve color(), oklch() or color-mix().
    colorContext.clearRect(0, 0, 1, 1);
    colorContext.fillStyle = value;
    colorContext.fillRect(0, 0, 1, 1);
    const [red, green, blue, alpha] = colorContext.getImageData(0, 0, 1, 1).data;
    return {red, green, blue, alpha: alpha / 255};
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

  function detectHighlightModeFromColors(backgroundColors) {
    if (!Array.isArray(backgroundColors) || !backgroundColors.length) return null;

    // The page canvas is white when no opaque background is declared.
    let composite = { red: 255, green: 255, blue: 255, alpha: 1 };
    for (let i = backgroundColors.length - 1; i >= 0; i -= 1) {
      const parsed = backgroundColors[i];
      if (!parsed || ![parsed.red, parsed.green, parsed.blue, parsed.alpha].every(Number.isFinite) ||
          parsed.alpha < 0 || parsed.alpha > 1) return null;
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

    try {
      return detectHighlightModeFromColors(backgroundColors.map(resolveBrowserColor));
    } catch (error) {
      console.error("PA3 extension: Could not resolve page background colors.", error);
      return null;
    }
  }

  const api = {
    detectHighlightMode,
    detectHighlightModeFromColors
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahHighlightTheme = api;
  }
})();
