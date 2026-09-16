const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

function setup(realAudio = false) {
  const played = [], ended = [], timers = [];
  const window = {ReedahFrameDetection:{shouldRunInFrame:()=>true, isEditorFrame:()=>false}};
  for (const [name, file] of Object.entries({
    ReedahSentence:'sentence', ReedahOverlayGeometry:'overlay_geometry', ReedahHoverBounds:'hover_bounds',
    ReedahHighlightRanges:'highlight_ranges', ReedahHighlightProgress:'highlight_progress',
    ReedahHighlightTheme:'highlight_theme', ReedahOrderedListNarration:'ordered_list_narration',
    ReedahPlaybackHistory:'playback_history', ReedahControlsNavigation:'controls_navigation',
    ReedahNarrationText:'narration_text'
  })) window[name] = require('../' + file);
  const context = vm.createContext({window, console,
    document:{readyState:'complete'},
    chrome:{runtime:{onMessage:{addListener() {}}, sendMessage() {}}},
    setTimeout(callback) { timers.push(callback); },
    Audio: class { play() { return Promise.resolve(); } pause() {} },
    URL:{revokeObjectURL() {}},
    played, ended
  });
  // Exercise the actual content-script queue; replace only DOM/audio output.
  const source = fs.readFileSync(path.join(__dirname, '../content.js'), 'utf8');
  vm.runInContext(source.replace(/\}\)\(\);\s*$/, `
    if (!${realAudio}) playNextAudio = (id, item) => {
      played.push(item.index);
      state.currentAudio = {};
      state.playbackStarted = true;
    };
    handleNarrationEnded = () => ended.push(true);
    updateHighlightForIndex = () => {};
    applyHighlightWordFocus = () => {};
    startHighlightWordFocusLoop = () => {};
    updateControls = () => {};
    createAudioUrl = text => text;
    globalThis.queueTest = {state, maybeStartPlayback, skipSentence, enqueueAudio};
  })();`), context);
  const {state, maybeStartPlayback} = context.queueTest;
  state.playbackId = 1;
  state.activeEl = {};
  return {state, start:()=>maybeStartPlayback(1), played, ended, timers, ...context.queueTest};
}

test('starts the first ready sentence while the model is still generating the paragraph', () => {
  const {state, start, played} = setup();
  state.audioQueue.push({index:0});
  state.nativeEnded = false;
  start();
  assert.deepEqual(played, [0]);
  assert.equal(state.audioQueue.length, 0);
});

test('queues subsequent sentences without interrupting current playback', () => {
  const {state, start, played} = setup();
  state.audioQueue.push({index:0}); start();
  state.audioQueue.push({index:1}); start();
  assert.deepEqual(played, [0]);
  state.currentAudio = null; start();
  assert.deepEqual(played, [0,1]);
});

test('pause and stale playback IDs do not consume ready audio', () => {
  const {state, start, played} = setup();
  state.audioQueue.push({index:0});
  state.isPaused = true; start();
  assert.equal(state.audioQueue.length, 1);
  state.isPaused = false; state.playbackId = 2; start();
  assert.equal(state.audioQueue.length, 1);
  assert.deepEqual(played, []);
});

test('first audio starts without an artificial paragraph lead-in', () => {
  const {state, start, played, timers} = setup();
  state.pendingLeadIn = true;
  state.audioQueue.push({index:0}); start();
  assert.equal(timers.length, 0);
  assert.deepEqual(played, [0]);
});

test('an empty queue waits for generation and ends only after its end event', () => {
  const {state, start, ended} = setup();
  start(); assert.equal(ended.length, 0);
  state.nativeEnded = true; start();
  assert.equal(ended.length, 1);
});

test('actual audio completion chains pieces immediately and pauses at the sentence boundary', () => {
  const {state, start, timers} = setup(true);
  state.audioQueue.push({url:'a', index:0, pieceIndex:0, pieceCount:2}, {url:'b',index:0,pieceIndex:1,pieceCount:2}, {url:'c',index:1,pieceIndex:0,pieceCount:1});
  start();
  state.currentAudio.onended();
  assert.equal(state.currentAudio.src, 'b');
  assert.equal(timers.length, 0);
  state.currentAudio.onended();
  assert.equal(timers.length, 1);
  timers[0]();
  assert.equal(state.currentAudio.src, 'c');
});
test('skip omits queued and late pieces of the same sentence', () => {
  const {state, start, skipSentence, enqueueAudio} = setup(true);
  state.audioQueue.push({url:'a',index:0,pieceIndex:0,pieceCount:3}, {url:'b',index:0,pieceIndex:1,pieceCount:3});
  start(); skipSentence();
  const session = {active:true, playbackId:1, audioQueue:state.audioQueue};
  enqueueAudio(session, {audioBase64:'late',index:0,pieceIndex:2,pieceCount:3});
  assert.equal(state.currentAudio, null);
  assert.deepEqual(Array.from(state.playedHistory, x => x.url), ['a','b','late']);
  enqueueAudio(session, {audioBase64:'next',index:1,pieceIndex:0,pieceCount:1});
  assert.equal(state.currentAudio.src, 'next');
});
