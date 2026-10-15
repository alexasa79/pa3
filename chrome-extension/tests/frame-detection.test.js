const assert = require("node:assert/strict");
const test = require("node:test");
const { shouldRunInFrame, isEditorFrame } = require("../frame_detection");

function makeWin(hostname, isTop) {
  const win = {
    location: { hostname }
  };
  win.top = isTop ? win : {};
  return win;
}

test("top-level window: should run, not editor frame", () => {
  const win = makeWin("en.wikipedia.org", true);
  assert.equal(shouldRunInFrame(win), true);
  assert.equal(isEditorFrame(win), false);
});

test("regular iframe (example.com): should run", () => {
  const win = makeWin("example.com", false);
  assert.equal(shouldRunInFrame(win), true);
  assert.equal(isEditorFrame(win), false);
});

test("Word Online editor iframe: should run, is editor frame", () => {
  const win = makeWin("usc-word-edit.officeapps.live.com", false);
  assert.equal(shouldRunInFrame(win), true);
  assert.equal(isEditorFrame(win), true);
});

test("OAuth iframe (oauth.officeapps.live.com): should not run", () => {
  const win = makeWin("oauth.officeapps.live.com", false);
  assert.equal(shouldRunInFrame(win), false);
  assert.equal(isEditorFrame(win), false);
});

test("shell iframe (webshell.suite.office.com): should not run", () => {
  const win = makeWin("webshell.suite.office.com", false);
  assert.equal(shouldRunInFrame(win), false);
  assert.equal(isEditorFrame(win), false);
});
