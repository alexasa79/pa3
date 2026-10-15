const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

test("options page includes test narration controls and handler wiring", () => {
  const htmlPath = path.join(__dirname, "..", "options.html");
  const jsPath = path.join(__dirname, "..", "options.js");
  const html = fs.readFileSync(htmlPath, "utf8");
  const js = fs.readFileSync(jsPath, "utf8");

  assert.match(html, /id="test-narration-text"/);
  assert.match(html, /id="test-narrate"/);
  assert.match(js, /function handleTestNarrationClick\(\)/);
  assert.match(js, /testNarrateButton\.addEventListener\("click", handleTestNarrationClick\);/);
});
