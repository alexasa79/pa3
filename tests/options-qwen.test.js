const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const html = fs.readFileSync(path.join(__dirname, '../options.html'), 'utf8');
const source = fs.readFileSync(path.join(__dirname, '../options.js'), 'utf8');
function setup() {
  const elements = new Map();
  function element() {
    return {value:'', style:{}, dataset:{}, textContent:'', children:[], addEventListener() {},
      appendChild(child) { this.children.push(child); }};
  }
  for (const [, id] of html.matchAll(/id="([^"]+)"/g)) elements.set(id, element());
  const writes = [], messages = [], reads = [];
  const port = {onMessage:{addListener() {}}, onDisconnect:{addListener() {}},
    postMessage(message) { messages.push(message); }, disconnect() {}};
  const context = vm.createContext({console,
    document:{getElementById(id) { assert.ok(elements.has(id), `Missing element: ${id}`); return elements.get(id); },
      documentElement:{dataset:{}}, addEventListener() {}, createElement:element, createTextNode(text) { return {textContent:text}; }},
    window:{setTimeout() {}, clearTimeout() {}, setInterval() {}, clearInterval() {}},
    chrome:{runtime:{connect() { return port; }}, storage:{local:{
      get(keys, callback) { reads.push([...keys]); callback({pa3Rate:1.25, pa3Voice:'am_adam', nativeVoice:'af_heart'}); },
      set(settings, callback) { writes.push(settings); callback(); }, remove(keys, callback) { callback(); }
    }}}
  });
  vm.runInContext(source, context);
  return {context, elements, writes, messages, reads};
}
test('Qwen settings initialize without any voice picker or stored preset dependency', () => {
  const {elements, reads} = setup();
  assert.doesNotMatch(html, /<select|am_adam|af_heart|Kokoro/i);
  assert.match(html, /Qwen3-TTS/);
  assert.match(html, /American senior engineer/);
  assert.deepEqual(reads, [['pa3Rate','pa3CustomVocab']]);
  assert.equal(elements.get('rate').value, '1.25');
});
test('test narration uses PA3 voice implicitly and retains playback speed', () => {
  const {context, messages} = setup();
  assert.equal(vm.runInContext('startPreviewRequest({text:"PA3 is ready."})', context), true);
  assert.equal(messages[0].text, 'PA3 is ready.');
  assert.equal(messages[0].rate, 1.25);
  assert.equal(Object.hasOwn(messages[0], 'voice'), false);
});
test('saving settings only writes supported controls and rejects invalid speed', () => {
  const {context, elements, writes} = setup();
  vm.runInContext('persistSettings("Saved")', context);
  assert.deepEqual(Object.keys(writes[0]), ['pa3Rate']);
  assert.equal(writes[0].pa3Rate, 1.25);
  elements.get('rate').value = '3';
  assert.equal(vm.runInContext('persistSettings("Saved")', context), false);
  assert.equal(writes.length, 1);
});
test('custom vocabulary displays plain spoken spellings without phoneme delimiters', () => {
  const {context, elements} = setup();
  vm.runInContext('vocabDraftEntries = [{spelling:"PA3", pronunciation:"P A three"}]; renderVocabList()', context);
  const row = elements.get('vocab-list').children[0];
  assert.equal(row.children[0].children[2].textContent, 'P A three');
});
