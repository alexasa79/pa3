const assert = require("node:assert/strict");
const test = require("node:test");
const {detectHighlightModeFromColors} = require("../highlight_theme");
const color=(red,green,blue,alpha=1)=>({red,green,blue,alpha});

test("highlight theme uses light mode for bright sRGB backgrounds",()=>{
  assert.equal(detectHighlightModeFromColors([color(248,250,252)]),"light");
});
test("highlight theme uses dark mode for dark sRGB backgrounds",()=>{
  assert.equal(detectHighlightModeFromColors([color(15,23,42)]),"dark");
});
test("highlight theme composites translucent child backgrounds over ancestors",()=>{
  assert.equal(detectHighlightModeFromColors([color(0,0,0,0.68),color(250,250,250)]),"dark");
  assert.equal(detectHighlightModeFromColors([color(255,255,255,0.8),color(0,0,0)]),"light");
});
test("opaque child background determines theme regardless of ancestor colors",()=>{
  assert.equal(detectHighlightModeFromColors([color(255,255,255),color(0,0,0)]),"light");
});
test("fully transparent backgrounds use the default white page canvas",()=>{
  assert.equal(detectHighlightModeFromColors([color(0,0,0,0)]),"light");
});
test("invalid color samples fail explicitly",()=>{
  for(const samples of [[],null,[null],[color(NaN,0,0)],[color(0,0,0,2)]]) {
    assert.equal(detectHighlightModeFromColors(samples),null);
  }
});
