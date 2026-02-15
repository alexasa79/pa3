const assert = require("node:assert/strict");
const test = require("node:test");
const { detectHighlightModeFromBackgroundColors } = require("../highlight_theme");

test("detectHighlightModeFromBackgroundColors returns light for bright backgrounds", () => {
  const mode = detectHighlightModeFromBackgroundColors(["rgb(248, 250, 252)"]);
  assert.equal(mode, "light");
});

test("detectHighlightModeFromBackgroundColors returns dark for dark backgrounds", () => {
  const mode = detectHighlightModeFromBackgroundColors(["rgb(15, 23, 42)"]);
  assert.equal(mode, "dark");
});

test("detectHighlightModeFromBackgroundColors blends translucent foreground layers", () => {
  const mode = detectHighlightModeFromBackgroundColors([
    "rgba(0, 0, 0, 0.68)",
    "rgb(250, 250, 250)"
  ]);
  assert.equal(mode, "dark");
});

test("detectHighlightModeFromBackgroundColors returns null for invalid colors", () => {
  const mode = detectHighlightModeFromBackgroundColors(["linear-gradient(red, blue)"]);
  assert.equal(mode, null);
});
