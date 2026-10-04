const assert = require("node:assert/strict");
const test = require("node:test");
const { buildSentenceRanges } = require("../sentence");
const { buildSentenceJobs } = require("../native_request_builder");

test("original dictionary terms, paths, identifiers and math reach PA3 with source offsets", () => {
  const text = "🙂 SQL in src/main.cpp uses type_name_t and X≥0. Then New York follows.";
  const ranges = buildSentenceRanges(text);
  const jobs = buildSentenceJobs(text, ranges);
  assert.deepEqual(jobs.map(job => job.text), ranges.map(r => text.slice(r.start, r.end)));
  assert.deepEqual(jobs.map(job => [job.location, job.length]), ranges.map(r => [r.start, r.end-r.start]));
});

test("invalid sentence ranges fail", () => {
  assert.throws(() => buildSentenceJobs("hello", [{start:0, end:"5"}]), /integer start/);
});

test("code references are omitted with source offsets intact", () => {
  const text = "(file.swift:1) 🙂 Read (src/file.swift:42) aloud. (src/file.swift:2) Then continue reading.";
  const jobs = buildSentenceJobs(text, buildSentenceRanges(text, {minSentenceLength: 0}));
  assert.deepEqual(jobs.map(job => job.text), ["🙂 Read aloud.", "Then continue reading."]);
  assert.deepEqual(jobs.map(job => text.slice(job.location, job.location + job.length)),
    ["🙂 Read (src/file.swift:42) aloud.", "Then continue reading."]);
});

test("code reference filtering spans supplied ranges and runs without changing text for dictionary matching", () => {
  const text = "Read (src/SQL.swift:42) aloud.";
  const jobs = buildSentenceJobs(text, [{start:0,end:10}, {start:10,end:20}, {start:20,end:text.length}]);
  assert.deepEqual(jobs.map(job => job.text), ["Read", "aloud."]);
  assert.deepEqual(jobs.map(job => job.index), [0, 2]);
  const reference = "(file.swift:42).";
  assert.deepEqual(buildSentenceJobs(reference, [{start:0,end:reference.length}]), []);
  const prose = "Read (SQL is useful) aloud.";
  assert.equal(buildSentenceJobs(prose, [{start:0,end:prose.length}])[0].text, "Read (SQL is useful) aloud.");
});

test("parentheses cleanup preserves meaningful text and punctuation", () => {
  for (const [text, expected] of [
    ["Read(file.c:100-200)aloud (file.ts:12:3).", "Read aloud."],
    ["Read (an important detail) aloud.", "Read (an important detail) aloud."],
    ["Read (an aside (nested)) aloud.", "Read (an aside (nested)) aloud."],
    ["Read (across\n\nparagraphs) aloud.", "Read (across\n\nparagraphs) aloud."],
    ["🙂 Read (שלום 🙂) aloud.", "🙂 Read (שלום 🙂) aloud."],
    ["Read (unfinished aloud.", "Read (unfinished aloud."],
    ["Call function() now.", "Call function() now."]
  ]) {
    assert.equal(buildSentenceJobs(text, [{start:0,end:text.length}])[0].text, expected);
  }
});

test('timed paragraph jobs keep original offsets through skipped code references', () => {
  const text='🙂 Read (file.swift:42). Then SQL.';
  const jobs=buildSentenceJobs(text,[{start:0,end:text.length}],{preserveOffsets:true});
  assert.equal(jobs[0].text,text);
  assert.equal(jobs[0].length,text.length);
});
