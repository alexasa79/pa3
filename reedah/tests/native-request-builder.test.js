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
