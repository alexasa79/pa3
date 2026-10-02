const assert = require("node:assert/strict");
const test = require("node:test");
const {buildSentenceJobs} = require("../native_request_builder");
test("original tokens reach PA3 before shared dictionary and pronunciation processing", () => {
  for (const token of ["type_name_t", "get_type_name(type_name_t)", "_private_t", "ns::get_name_t()", "café_type_t"]) {
    const text = "🙂 Read " + token + " now.";
    assert.deepEqual(buildSentenceJobs(text, [{start:0,end:text.length}]),
      [{index:0, location:0, length:text.length, text}]);
  }
});
