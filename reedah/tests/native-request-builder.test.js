const assert = require("node:assert/strict");
const test = require("node:test");
const { buildSentenceRanges } = require("../sentence");
const {
  applyCustomVocab,
  buildSentenceJobs
} = require("../native_request_builder");

test("applyCustomVocab replaces whole-word matches with spoken spellings", () => {
  const customVocab = [{ spelling: "REPL", pronunciation: "repul" }];
  const result = applyCustomVocab(
    "It must support REPL workflow. PREPL should stay unchanged.",
    customVocab
  );

  assert.equal(
    result,
    "It must support repul workflow. PREPL should stay unchanged."
  );
});

test("buildSentenceJobs keeps original location/length while transforming sentence text", () => {
  const text = "It must support REPL workflow.";
  const sentenceRanges = [{ start: 0, end: text.length }];
  const customVocab = [{ spelling: "REPL", pronunciation: "repul" }];

  const jobs = buildSentenceJobs(text, sentenceRanges, customVocab);

  assert.equal(jobs.length, 1);
  assert.deepEqual(jobs[0], {
    index: 0,
    location: 0,
    length: text.length,
    text: "It must support repul workflow."
  });
});

test("buildSentenceJobs rejects invalid sentence ranges", () => {
  assert.throws(
    () => buildSentenceJobs("hello", [{ start: 0, end: "5" }], []),
    /sentenceRanges\[0\] must include integer start\/end/
  );
});

test("range and quote boundaries reach model jobs without changing highlight offsets", () => {
  const first = '🙂 He said "Use SQL across A..B for these records."';
  const second = "Then inspect the result with the next query.";
  const text = `${first} ${second}`;
  const jobs = buildSentenceJobs(text, buildSentenceRanges(text), [{ spelling: "SQL", pronunciation: "sequel" }]);
  assert.deepEqual(jobs, [
    { index: 0, location: 0, length: first.length, text: first.replace("SQL", "sequel") },
    { index: 1, location: first.length + 1, length: second.length, text: second }
  ]);
});

test("math comparisons are spoken explicitly without shifting sentence highlight offsets", () => {
  const text = "🙂 First check that X≥0 holds. Then compare X ≤ 10, X≠5, and X≈3.";
  const ranges = buildSentenceRanges(text);
  const jobs = buildSentenceJobs(text, ranges, []);
  assert.deepEqual(jobs.map(job => job.text), [
    "🙂 First check that X is greater than or equal to 0 holds.",
    "Then compare X is less than or equal to 10, X is not equal to 5, and X is approximately equal to 3."
  ]);
  assert.deepEqual(jobs.map(job => [job.location, job.length]),
    ranges.map(range => [range.start, range.end - range.start]));
});

test("math pronunciation preserves vocabulary substitutions and ordinary code punctuation", () => {
  const text = "Check limit≥0 in a_b.cpp, then x + y = z and https://example.org/a_b.";
  const jobs = buildSentenceJobs(text, [{start: 0, end: text.length}], [
    {spelling: "limit", pronunciation: "upper bound"}
  ]);
  assert.equal(jobs[0].text,
    "Check upper bound is greater than or equal to 0 in a underscore b dot C P P, then x + y = z and https://example.org/a_b.");
});

test("code references are omitted with source offsets intact", () => {
  const text = "(file.swift:1) 🙂 Read (src/file.swift:42) aloud. (src/file.swift:2) Then continue reading.";
  const jobs = buildSentenceJobs(text, buildSentenceRanges(text, {minSentenceLength: 0}), []);
  assert.deepEqual(jobs.map(job => job.text), ["🙂 Read aloud.", "Then continue reading."]);
  assert.deepEqual(jobs.map(job => text.slice(job.location, job.location + job.length)),
    ["🙂 Read (src/file.swift:42) aloud.", "Then continue reading."]);
});

test("code reference filtering spans supplied ranges and runs before vocabulary", () => {
  const text = "Read (src/SQL.swift:42) aloud.";
  const jobs = buildSentenceJobs(text, [{start:0,end:10}, {start:10,end:20}, {start:20,end:text.length}],
    [{spelling:"SQL", pronunciation:"sequel"}]);
  assert.deepEqual(jobs.map(job => job.text), ["Read", "aloud."]);
  assert.deepEqual(jobs.map(job => job.index), [0, 2]);
  const reference = "(file.swift:42).";
  assert.deepEqual(buildSentenceJobs(reference, [{start:0,end:reference.length}], []), []);
  const prose = "Read (SQL is useful) aloud.";
  assert.equal(buildSentenceJobs(prose, [{start:0,end:prose.length}],
    [{spelling:"SQL", pronunciation:"sequel"}])[0].text, "Read (sequel is useful) aloud.");
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
    assert.equal(buildSentenceJobs(text, [{start:0,end:text.length}], [])[0].text, expected);
  }
});
