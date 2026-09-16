const test = require("node:test");
const assert = require("node:assert/strict");
const { Assembler } = require("../audio_transfer");
const chunk = (part, final, audioBase64) => ({utteranceId: "a", index: 0, location: 12, length: 8, part, final, audioBase64});
test("reassembles native audio while preserving source position", () => {
  const assembler = new Assembler();
  assert.equal(assembler.accept(chunk(0, false, "UklG")), null);
  const result = assembler.accept(chunk(1, true, "Rg=="));
  assert.equal(Buffer.from(result.audioBase64, "base64").toString(), "RIFF");
  assert.equal(result.location, 12);
  assert.equal(result.length, 8);
  assert.equal(result.event, "audio");
});
test("rejects stale, out-of-order and malformed audio", () => {
  assert.throws(() => new Assembler().accept(chunk(1, true, "Rg==")), /order/);
  assert.throws(() => new Assembler().accept(chunk(0, true, "!")), /Malformed/);
  const assembler = new Assembler();
  assembler.accept(chunk(0, false, "UklG"));
  assert.throws(() => assembler.accept({...chunk(1, true, "Rg=="), utteranceId: "b"}), /order/);
});

test("consecutive pieces retain their progress and cannot mix native message parts", () => {
  const assembler = new Assembler();
  const first = {...chunk(0, true, "UklGRg=="), pieceIndex:0, pieceCount:2, progressStart:0, progressEnd:0.4};
  assert.equal(assembler.accept(first).progressEnd, 0.4);
  const second = {...first, pieceIndex:1, progressStart:0.4, progressEnd:1};
  assert.equal(assembler.accept(second).pieceIndex, 1);
  assembler.accept({...first, final:false});
  assert.throws(() => assembler.accept({...second, part:1}), /order/);
});
