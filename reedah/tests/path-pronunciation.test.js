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
    ["a_b_c.cpp", "a underscore b underscore c dot C P P"],
    ["a__b.cpp", "a underscore underscore b dot C P P"],
    ["a/b/c", "a slash b slash c"],
    ["setup.bash", "setup dot bash"],
    ["setup.zsh", "setup dot Z S H"],
    ["setup.ps1", "setup dot P S one"],
    ["main.c++", "main dot C plus plus"],
    ["include/main.h++", "include slash main dot H plus plus"],
    ["app.py", "app dot P Y"],
    ["analysis.ipynb", "analysis dot I P Y N B"],
    ["main.go", "main dot go"],
    ["go.mod", "go dot mod"],
    ["types.d.ts", "types dot D dot T S"],
    ["bundle.min.mjs", "bundle dot min dot M J S"],
    ["Main.java", "Main dot java"],
    ["main.rs", "main dot R S"],
    ["project.csproj", "project dot C S P R O J"],
    ["report.DOCX", "report dot D O C X"],
    ["report.docm", "report dot D O C M"],
    ["template.dotx", "template dot D O T X"],
    ["budget.xls", "budget dot X L S"],
    ["budget.xlsx", "budget dot X L S X"],
    ["budget.xlsm", "budget dot X L S M"],
    ["budget.xlsb", "budget dot X L S B"],
    ["slides.pptx", "slides dot P P T X"],
    ["slides.ppsm", "slides dot P P S M"],
    ["contacts.accdb", "contacts dot A C C D B"],
    ["diagram.vsdx", "diagram dot V S D X"],
    ["notes.one", "notes dot one"],
    ["report.odt", "report dot O D T"],
    ["book.epub", "book dot epub"],
    ["photo.heic", "photo dot heic"],
    ["clip.mp3", "clip dot M P three"],
    ["clip.mp4", "clip dot M P four"],
    ["backup.7z", "backup dot seven Z"],
    ["build/backup.7z", "build slash backup dot seven Z"],
    ["archive.tar.bz2", "archive dot tar dot B Z two"],
    ["data.parquet", "data dot parquet"],
    ["application.dmg", "application dot D M G"],
    ["font.woff2", "font dot W O F F two"],
    ["certificate.p12", "certificate dot P one two"],
    ["src/custom.unlisted", "src slash custom dot unlisted"]
  ]) {
    assert.equal(pronouncePaths(`Open ${path}.`), `Open ${spoken}.`, path);
    assert.equal(pronouncePaths(pronouncePaths(`Open ${path}.`)), `Open ${spoken}.`, "normalization is idempotent");
  }
});

test("file references pronounce line numbers with a pause and preserve existing punctuation", () => {
  for (const [text, spoken] of [
    ["a_b.cpp:888", "a underscore b dot C P P, line 888,"],
    ["Open src/a_b.cpp:888 next.", "Open src slash a underscore b dot C P P, line 888, next."],
    ["Open a_b.cpp:888.", "Open a underscore b dot C P P, line 888."],
    ["a_b.cpp:888, then continue.", "a underscore b dot C P P, line 888, then continue."],
    ["a_b.cpp:888: error", "a underscore b dot C P P, line 888: error"],
    ['Read "a_b.cpp:888".', 'Read "a underscore b dot C P P, line 888".'],
    ["See (a_b.cpp:888).", "See (a underscore b dot C P P, line 888)."],
    ["Read `a_b.cpp:888` next.", "Read `a underscore b dot C P P, line 888` next."],
    ["../src/a_b.cpp:888:12", "dot dot slash src slash a underscore b dot C P P, line 888, column 12,"],
    ["/tmp/Makefile:12", "slash tmp slash Makefile, line 12,"],
    ["a_b.cpp:888!", "a underscore b dot C P P, line 888!"],
    ["a_b.cpp:888; next", "a underscore b dot C P P, line 888; next"]
  ]) {
    assert.equal(pronouncePaths(text), spoken, text);
    assert.equal(pronouncePaths(spoken), spoken, "already-prepared line references stay unchanged");
  }
});

test("line-number parsing leaves URLs, times, and malformed references unchanged", () => {
  for (const text of [
    "https://host:888/src/a_b.cpp:22", "example.org/a_b.cpp:888", "12:34", "3.14:5", "ratio:888",
    "a_b.cpp:eight", "a_b.cpp:-8", "a_b.cpp:8:column", "a_b.cpp:8:12:34",
    "https://host/src/file.c:100-200", "example.org/file.c:100-200", "100-200", "12:34-56",
    "file.c:100-", "file.c:-200", "file.c:100--200", "file.c:100-200-300", "file.c:100-two",
    "file.c:100-200:3", "file.c:100:2-200:3"
  ]) assert.equal(pronouncePaths(text), text);
});

test("line ranges say lines start to end and preserve punctuation", () => {
  for (const [text, spoken] of [
    ["file.c:100-200", "file dot C, lines 100 to 200,"],
    ["Check file.c:100-200.", "Check file dot C, lines 100 to 200."],
    ["src/a_b.cpp:100-200 next.", "src slash a underscore b dot C P P, lines 100 to 200, next."],
    ["file.c:100-200, then continue.", "file dot C, lines 100 to 200, then continue."],
    ["file.c:100-200: note", "file dot C, lines 100 to 200: note"],
    ['Read "file.c:100-200".', 'Read "file dot C, lines 100 to 200".'],
    ["See (file.c:100-200).", "See (file dot C, lines 100 to 200)."],
    ["Read `file.c:100-200` next.", "Read `file dot C, lines 100 to 200` next."],
    ["../src/file.c:100-200", "dot dot slash src slash file dot C, lines 100 to 200,"],
    ["/tmp/Makefile:100-200", "slash tmp slash Makefile, lines 100 to 200,"],
    ["file-100-200.c", "file dash 100 dash 200 dot C"]
  ]) {
    assert.equal(pronouncePaths(text), spoken, text);
    assert.equal(pronouncePaths(spoken), spoken, "already-prepared line ranges stay unchanged");
  }
});

test("line ranges preserve original sentence offsets and vocabulary overrides", () => {
  const first = "🙂 Check file.c:100-200 before editing.";
  const second = "Then inspect src/a_b.cpp:300-400.";
  const text = `${first} ${second}`;
  assert.deepEqual(buildSentenceJobs(text, buildSentenceRanges(text), []), [
    { index: 0, location: 0, length: first.length, text: "🙂 Check file dot C, lines 100 to 200, before editing." },
    { index: 1, location: first.length + 1, length: second.length, text: "Then inspect src slash a underscore b dot C P P, lines 300 to 400." }
  ]);
  const override = buildSentenceJobs(first, [{start: 0, end: first.length}], [
    {spelling: "file.c:100-200", pronunciation: "the affected lines"}
  ]);
  assert.equal(override[0].text, "🙂 Check the affected lines before editing.");
  assert.equal(override[0].length, first.length);
});

test("line references preserve original sentence offsets and vocabulary overrides", () => {
  const first = "🙂 Check a_b.cpp:888 before editing.";
  const second = "Then inspect src/c_d.hpp:12.";
  const text = `${first} ${second}`;
  assert.deepEqual(buildSentenceJobs(text, buildSentenceRanges(text), []), [
    { index: 0, location: 0, length: first.length, text: "🙂 Check a underscore b dot C P P, line 888, before editing." },
    { index: 1, location: first.length + 1, length: second.length, text: "Then inspect src slash c underscore d dot H P P, line 12." }
  ]);
  const override = buildSentenceJobs(first, [{start: 0, end: first.length}], [
    {spelling: "a_b.cpp:888", pronunciation: "the failing line"}
  ]);
  assert.equal(override[0].text, "🙂 Check the failing line before editing.");
  assert.equal(override[0].length, first.length);
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
    "See file:///Users/me/main.cpp and ssh://host/a/b/c.", "Email user@example.org.",
    "Visit https://example.org/report.docx and www.example.org/backup.7z.",
    "Unknown custom.unlisted and version 3.7 stay unchanged."
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
