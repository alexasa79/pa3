const assert = require("node:assert/strict");
const test = require("node:test");
const { pronounceIdentifiers, buildSentenceJobs } = require("../native_request_builder");
const { buildSentenceRanges } = require("../sentence");

test("identifiers pronounce every underscore and give single letters their names", () => {
  for (const [text, spoken] of [
    ["type_name_t", "type underscore name underscore tee"],
    ["uint32_t", "uint32 underscore tee"],
    ["get_type_name()", "get underscore type underscore name()"],
    ["get_type_name(type_name_t)", "get underscore type underscore name(type underscore name underscore tee)"],
    ["ns::get_name_t()", "ns::get underscore name underscore tee()"],
    ["x_y_t", "ex underscore why underscore tee"],
    ["TYPE_NAME_T", "TYPE underscore NAME underscore tee"],
    ["_private_t", "underscore private underscore tee"],
    ["__init__", "underscore underscore init underscore underscore"],
    ["type__t", "type underscore underscore tee"],
    ["type_name_", "type underscore name underscore"],
    ["value_1", "value underscore 1"],
    ["naïve_type_t", "naïve underscore type underscore tee"],
    ["cafe\u0301_type_t", "cafe\u0301 underscore type underscore tee"],
    ["constructor_t", "constructor underscore tee"],
    ["__proto__", "underscore underscore proto underscore underscore"],
    ['Use "type_name_t".', 'Use "type underscore name underscore tee".'],
    ["Use `type_name_t`; (get_name_t()).", "Use `type underscore name underscore tee`; (get underscore name underscore tee())."],
    ["type_name_t*", "type underscore name underscore tee*"],
    ["type_name_t,other_type_t", "type underscore name underscore tee,other underscore type underscore tee"]
  ]) {
    assert.equal(pronounceIdentifiers(text), spoken, text);
    assert.equal(pronounceIdentifiers(spoken), spoken, "prepared names stay unchanged");
  }
});

test("identifier pronunciation preserves paths, URLs, email, numbers, and ordinary prose", () => {
  for (const text of [
    "A normal sentence about t and tea.", "1_000 1_name_t _123 ____",
    "src/type_name_t.cpp:100-200", "type_name_t.cpp", "type_name_t.unknown", "./type_name_t",
    "https://example.org/type_name_t?next=get_name_t", "www.example.org/type_name_t",
    "example.org/type_name_t", "user_name@example.org", ".hidden_name", "pkg.type_name_t"
  ]) assert.equal(pronounceIdentifiers(text), text);
  assert.throws(() => pronounceIdentifiers(null), /Narration text must be a string/);
});

test("identifier speech preserves sentence offsets and full-name vocabulary overrides", () => {
  const first = "🙂 Use type_name_t here.";
  const second = "Then call get_type_name().";
  const text = `${first} ${second}`;
  assert.deepEqual(buildSentenceJobs(text, buildSentenceRanges(text), []), [
    { index: 0, location: 0, length: first.length, text: "🙂 Use type underscore name underscore tee here." },
    { index: 1, location: first.length + 1, length: second.length, text: "Then call get underscore type underscore name()." }
  ]);
  const jobs = buildSentenceJobs(text, buildSentenceRanges(text), [
    { spelling: "type_name_t", pronunciation: "the type name" },
    { spelling: "get_type_name", pronunciation: "the lookup function" }
  ]);
  assert.deepEqual(jobs.map(job => job.text), ["🙂 Use the type name here.", "Then call the lookup function()."]);
  assert.deepEqual(jobs.map(job => job.length), [first.length, second.length]);
});

test("filename and line-range pronunciation runs alongside standalone identifiers", () => {
  const text = "Check type_name_t in src/type_name_t.cpp:100-200.";
  const jobs = buildSentenceJobs(text, buildSentenceRanges(text), []);
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].text, "Check type underscore name underscore tee in src slash type underscore name underscore t dot C P P, lines 100 to 200.");
  assert.equal(jobs[0].length, text.length);
});
