const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

test('every keyboard command acknowledges delivery, including disabled playback', () => {
  const source = fs.readFileSync(path.join(__dirname, '../content.js'), 'utf8');
  const start = source.indexOf('  chrome.runtime.onMessage.addListener(');
  const end = source.indexOf('\n  if (document.readyState', start);
  let receive;
  const calls = [];
  const state = {enabled:false};
  // Run the actual message listener; only its UI and playback actions are mocked.
  vm.runInNewContext(source.slice(start, end), {
    chrome:{runtime:{onMessage:{addListener(fn) { receive = fn; }}}}, state,
    toggle() { calls.push('toggle'); }, togglePause() { calls.push('pause'); },
    playPreviousSentence() { calls.push('previous'); }, skipSentence() { calls.push('next'); }
  });
  for (const enabled of [false, true]) {
    state.enabled = enabled;
    calls.length = 0;
    for (const type of ['reedah-toggle', 'reedah-pause', 'reedah-previous-sentence', 'reedah-next-sentence']) {
      const replies = [];
      receive({type}, {}, value => replies.push(value));
      assert.equal(replies.length, 1, `${type} must acknowledge delivery`);
      assert.equal(replies[0].enabled, enabled);
    }
    assert.deepEqual(calls, enabled ? ['toggle','pause','previous','next'] : ['toggle','pause']);
  }
  let unexpectedReply = false;
  receive({type:'unrelated-message'}, {}, () => unexpectedReply = true);
  assert.equal(unexpectedReply, false);
});
