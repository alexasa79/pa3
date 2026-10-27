const assert = require("node:assert/strict");
const test = require("node:test");
const {buildNarrationJobs} = require("../native_request_builder");

test("one original source reaches PA3 with paragraphs and UTF-16 offsets intact", () => {
  for (const text of [
    "  🙂 SQL in src/main.cpp uses type_name_t and X≥0. Then New York follows.\n\nNext paragraph.  ",
    "Read (src/SQL.swift:42) aloud. (https://example.org) Then continue.",
    "(file.swift:42).",
    "Read (across\n\nparagraphs) aloud.",
    "Read(file.c:100-200)aloud (file.ts:12:3).",
    "Start. " + "keep this sentence together ".repeat(200) + "until the end."
  ]) {
    assert.deepEqual(buildNarrationJobs(text), [{index:0, location:0, length:text.length, text}]);
  }
});

test("invalid or oversized sources fail and empty sources create no job", () => {
  assert.throws(() => buildNarrationJobs(null), /must be a string/);
  assert.throws(() => buildNarrationJobs("x".repeat(100001)), /100,000/);
  assert.deepEqual(buildNarrationJobs(" \n\t "), []);
});
