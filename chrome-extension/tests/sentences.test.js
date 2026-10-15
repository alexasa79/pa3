const assert = require("node:assert/strict");
const test = require("node:test");
const { buildSentenceRanges } = require("../sentence");

function extractSentences(text, options) {
  return buildSentenceRanges(text, options).map((range) => text.slice(range.start, range.end));
}

test("buildSentenceRanges keeps abbreviations and decimals intact", () => {
  const text = "Use e.g. 3.14 in a sentence that is long enough to stay intact. " +
    "Another sentence that is also long enough to be separate.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.ok(sentences[0].includes("e.g."));
  assert.ok(sentences[0].includes("3.14"));
});

test("buildSentenceRanges keeps Mr. attached to the following name", () => {
  const text = "Mr. Smith delivered a detailed update during the weekly planning meeting. " +
    "The next sentence is also long enough to be separate.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.equal(sentences[0], "Mr. Smith delivered a detailed update during the weekly planning meeting.");
  assert.equal(sentences[1], "The next sentence is also long enough to be separate.");
});

test("buildSentenceRanges does not split on mid-word periods", () => {
  const text = "Vert.x is a reactive toolkit for the JVM. " +
    "It also supports Node.js style APIs and ASP.NET patterns.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.ok(sentences[0].includes("Vert.x"));
  assert.ok(sentences[1].includes("Node.js"));
  assert.ok(sentences[1].includes("ASP.NET"));
});

test("buildSentenceRanges does not split on acronym-ending periods", () => {
  const text = "The U.S. economy grew steadily through the decade. " +
    "The A.I. sector also expanded rapidly in the same period.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.ok(sentences[0].includes("U.S."));
  assert.ok(sentences[1].includes("A.I."));
});

test("buildSentenceRanges ends a sentence after a decimal number", () => {
  const text = "The ratio was 1.5 for the sample set. " +
    "The following sentence is also long enough to be separate.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.equal(sentences[0], "The ratio was 1.5 for the sample set.");
  assert.equal(sentences[1], "The following sentence is also long enough to be separate.");
});

test("buildSentenceRanges keeps two-dot ranges inside their sentences", () => {
  for (const range of ["A..B", "1..10", "A .. B", "-5..-1", "α..ω", "items[0]..items[n]"]) {
    const first = `Use ${range} to select the complete range.`;
    const second = "The following sentence describes the result.";
    assert.deepEqual(extractSentences(`${first} ${second}`, { minSentenceLength: 0 }), [first, second], range);
  }
});

test("buildSentenceRanges recognizes the real period after a range", () => {
  const first = "The allowed range is A..B.";
  const second = "The following sentence describes the result.";
  assert.deepEqual(extractSentences(`${first} ${second}`, { minSentenceLength: 0 }), [first, second]);
});

test("buildSentenceRanges keeps closing quotes and brackets with sentence punctuation", () => {
  for (const [opening, closing] of [['"', '"'], ['“', '”'], ["'", "'"], ['‘', '’'], ['«', '»']]) {
    for (const punctuation of [".", "?", "!", "?!"]) {
      const first = `The editor said ${opening}This article is ready${punctuation}${closing}`;
      const second = "The next paragraph explains the details.";
      // Exercise the normal short-sentence merge as well as the raw boundaries.
      for (const options of [undefined, { minSentenceLength: 0 }]) {
        assert.deepEqual(extractSentences(`${first} ${second}`, options), [first, second]);
      }
      assert.deepEqual(extractSentences(first, { minSentenceLength: 0 }), [first]);
    }
  }
});

test("buildSentenceRanges preserves offsets for quotes, Unicode, and repeated ranges", () => {
  const first = '🙂 The editor said "Use A..B and 1..10 for these ranges."';
  const second = '“Continue with α .. ω.”';
  const text = `  ${first}\n\t${second}  `;
  assert.deepEqual(buildSentenceRanges(text, { minSentenceLength: 0 }), [
    { start: 2, end: 2 + first.length },
    { start: 4 + first.length, end: 4 + first.length + second.length }
  ]);
});

test("buildSentenceRanges still handles ellipses and punctuation outside quotes", () => {
  for (const first of ['Wait...', 'The label is "ready".', 'The value is 3.14.', 'He said "Wait..."', 'He said "Stop!".']) {
    const second = "Then continue.";
    assert.deepEqual(extractSentences(`${first} ${second}`, { minSentenceLength: 0 }), [first, second]);
  }
});

test('paragraph ranges retain several sentences and bound very long paragraphs', () => {
  const {buildParagraphRanges}=require('../sentence');
  const text='First sentence. Second sentence.\n\nNext paragraph.';
  assert.deepEqual(buildParagraphRanges(text).map(r=>text.slice(r.start,r.end)),['First sentence. Second sentence.','Next paragraph.']);
  const long='A useful technical explanation. '.repeat(200);
  const ranges=buildParagraphRanges(long);
  assert.equal(ranges.map(r=>long.slice(r.start,r.end)).join(''),long);
  assert.ok(ranges.every(r=>r.end-r.start<=3800));
});

test('navigation sentences remain independent of paragraph transport ranges', () => {
  const {buildNavigationTargets} = require('../sentence');
  const text='Yes. No. A longer third sentence.';
  assert.deepEqual(buildNavigationTargets(text,[{start:0,end:text.length}]).map(s=>text.slice(s.start,s.end).trim()),
    ['Yes.','No.','A longer third sentence.']);
  const split=text.indexOf('A longer');
  assert.deepEqual(buildNavigationTargets(text,[{start:0,end:split},{start:split,end:text.length}]).map(s=>s.passageIndex),[0,0,1]);
});
