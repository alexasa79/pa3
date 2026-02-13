const assert = require("node:assert/strict");
const test = require("node:test");
const { addPlayedItem, shouldRevokeUrl, takeSkippedItem } = require("../playback_history");

test("addPlayedItem appends all played sentences without trimming", () => {
  const history = [];
  addPlayedItem(history, { url: "blob:1", index: 0 });
  addPlayedItem(history, { url: "blob:2", index: 1 });
  addPlayedItem(history, { url: "blob:3", index: 2 });
  addPlayedItem(history, { url: "blob:4", index: 3 });
  addPlayedItem(history, { url: "blob:5", index: 4 });

  assert.equal(history.length, 5);
  assert.deepEqual(history.map((item) => item.url), [
    "blob:1",
    "blob:2",
    "blob:3",
    "blob:4",
    "blob:5"
  ]);
});

test("addPlayedItem ignores invalid entries", () => {
  const history = [];
  addPlayedItem(history, null);
  addPlayedItem(history, { index: 3 });
  addPlayedItem(history, { url: "", index: 0 });
  assert.equal(history.length, 0);
});

test("shouldRevokeUrl returns false when url is in history", () => {
  const history = [{ url: "blob:1" }];
  const queue = [];
  assert.equal(shouldRevokeUrl("blob:1", history, queue), false);
});

test("shouldRevokeUrl returns false when url is still queued", () => {
  const history = [];
  const queue = [{ url: "blob:1" }];
  assert.equal(shouldRevokeUrl("blob:1", history, queue), false);
});

test("shouldRevokeUrl returns true only when url is untracked", () => {
  const history = [{ url: "blob:2" }];
  const queue = [{ url: "blob:3" }];
  assert.equal(shouldRevokeUrl("blob:1", history, queue), true);
});

test("takeSkippedItem prefers current item when available", () => {
  const current = { url: "blob:current", index: 2 };
  const queue = [{ url: "blob:queued", index: 3 }];
  const skipped = takeSkippedItem(current, queue);
  assert.equal(skipped, current);
  assert.equal(queue.length, 1);
});

test("takeSkippedItem consumes queued item when no current item", () => {
  const queue = [
    { url: "blob:first", index: 4 },
    { url: "blob:second", index: 5 }
  ];
  const skipped = takeSkippedItem(null, queue);
  assert.deepEqual(skipped, { url: "blob:first", index: 4 });
  assert.equal(queue.length, 1);
  assert.deepEqual(queue[0], { url: "blob:second", index: 5 });
});

test("takeSkippedItem returns null when no valid skip target exists", () => {
  assert.equal(takeSkippedItem(null, []), null);
  assert.equal(takeSkippedItem(null, null), null);
  const queue = [{ url: "blob:x" }];
  assert.deepEqual(takeSkippedItem({ index: 1 }, queue), { url: "blob:x" });
  assert.equal(queue.length, 0);
  assert.equal(takeSkippedItem(null, [{ index: 1 }]), null);
});
