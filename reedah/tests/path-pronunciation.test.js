const assert = require("node:assert/strict");
const test = require("node:test");
const { pronouncePaths, buildSentenceJobs } = require("../native_request_builder");
const { buildSentenceRanges } = require("../sentence");

test("paths pronounce separators and source-file extensions explicitly", () => {
  for (const [path, spoken] of [
    ["a/b/c/something.cpp", "a slash b slash c slash something dot C P P"],
    ["src/rte/red_app_spdk.cpp", "src slash rte slash red underscore app underscore spdk dot C P P"],
    ["/usr/local/bin/tool", "slash usr slash local slash bin slash tool"],
    ["./src/main.cpp", "dot slash src slash main dot C P P"],
    ["../include/main.hpp", "dot dot slash include slash main dot H P P"],
    ["~/code/my-project/main.CPP", "tilde slash code slash my dash project slash main dot C P P"],
    ["src/.config/settings.json", "src slash dot config slash settings dot json"],
    ["src/version1.2/main.cpp", "src slash version1 dot 2 slash main dot C P P"],
    ["build/archive.tar.gz", "build slash archive dot tar dot G Z"],
    ["/Users/山田/main.swift", "slash Users slash 山田 slash main dot swift"],
    ["src/assets/", "src slash assets slash"],
    ["something.cpp", "something dot C P P"],
    ["a/b/c", "a slash b slash c"]
  ]) {
    assert.equal(pronouncePaths(`Open ${path}.`), `Open ${spoken}.`, path);
    assert.equal(pronouncePaths(pronouncePaths(`Open ${path}.`)), `Open ${spoken}.`, "normalization is idempotent");
  }
});

test("path pronunciation preserves surrounding quotes and punctuation", () => {
  assert.equal(pronouncePaths('Read "src/main.cpp", then (include/main.hpp).'),
    'Read "src slash main dot C P P", then (include slash main dot H P P).');
  assert.equal(pronouncePaths('Read `src/main.cpp`; “include/main.hpp” follows.'),
    'Read `src slash main dot C P P`; “include slash main dot H P P” follows.');
  assert.equal(pronouncePaths('src/main.cpp,include/main.hpp'),
    'src slash main dot C P P,include slash main dot H P P');
});

test("ordinary slash expressions, ranges, numbers, and URLs remain unchanged", () => {
  for (const text of [
    "Use and/or, read/write, I/O, and TCP/IP.", "On 2026/09/17 use 1/2 of 3.14.",
    "A..B and A..c are ranges. Wait... Then continue.", "Use ASP.NET and version 3.14.",
    "Visit https://example.org/src/main.cpp?x=a/b/c and https://example.org/a,b.cpp.",
    "Visit (https://example.org/a,b.cpp).", "See www.example.org/src/main.cpp or example.org/src/main.cpp.",
    "See file:///Users/me/main.cpp and ssh://host/a/b/c.", "Email user@example.org."
  ]) assert.equal(pronouncePaths(text), text);
});

test("path speech keeps original sentence locations and custom path overrides", () => {
  const first = '🙂 Open "src/main.cpp" now.';
  const second = "Then inspect include/main.hpp carefully.";
  const text = `${first} ${second}`;
  const jobs = buildSentenceJobs(text, buildSentenceRanges(text), []);
  assert.deepEqual(jobs, [
    { index: 0, location: 0, length: first.length, text: '🙂 Open "src slash main dot C P P" now.' },
    { index: 1, location: first.length + 1, length: second.length, text: "Then inspect include slash main dot H P P carefully." }
  ]);
  const override = buildSentenceJobs(first, [{ start: 0, end: first.length }], [
    { spelling: "src/main.cpp", pronunciation: "the main source file" }
  ]);
  assert.equal(override[0].text, '🙂 Open "the main source file" now.');
  assert.equal(override[0].length, first.length);
});
