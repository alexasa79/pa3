const assert = require("node:assert/strict");
const test = require("node:test");
const {buildSentenceJobs} = require("../native_request_builder");
test("original tokens reach PA3 before shared dictionary and pronunciation processing", () => {
  for (const token of ["src/main.cpp", "file.c:100-200", "a_b.cpp:888", "include/main.hpp", "https://example.org/a_b", "./config", "/Users/me/file.swift"]) {
    const text = "🙂 Read " + token + " now.";
    assert.deepEqual(buildSentenceJobs(text, [{start:0,end:text.length}]),
      [{index:0, location:0, length:text.length, text}]);
  }
});
