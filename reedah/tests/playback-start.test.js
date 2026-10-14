const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

function setup(realAudio = false, completionRace = false) {
  const played = [], ended = [], timers = [], prefetched = [];
  const window = {ReedahFrameDetection:{shouldRunInFrame:()=>true, isEditorFrame:()=>false}};
  for (const [name, file] of Object.entries({
    ReedahSentence:'sentence', ReedahOverlayGeometry:'overlay_geometry', ReedahHoverBounds:'hover_bounds',
    ReedahHighlightRanges:'highlight_ranges', ReedahHighlightProgress:'highlight_progress',
    ReedahHighlightTheme:'highlight_theme', ReedahOrderedListNarration:'ordered_list_narration',
    ReedahPlaybackHistory:'playback_history', ReedahControlsNavigation:'controls_navigation',
    ReedahProseParagraphs:'prose_paragraphs', ReedahNarrationText:'narration_text', ReedahMathNarration:'math_narration', ReedahEditorNarration:'editor_narration'
  })) window[name] = require('../' + file);
  const streamContext = {currentTime:0, destination:{}, resume:async()=>{},
    createBuffer() { return {copyToChannel() {}}; },
    createBufferSource() { return {playbackRate:{},connect(){},disconnect(){},start(){},stop(){}}; }};
  const {StreamAudio} = require('../stream_audio');
  const context = vm.createContext({window, console,
    ReedahStreamAudio:{StreamAudio:class extends StreamAudio {
      constructor(options) { super({...options, getContext:()=>streamContext}); }
    }},
    document:{readyState:'complete'},
    chrome:{runtime:{onMessage:{addListener() {}}, sendMessage() {}}},
    setTimeout(callback) { timers.push(callback); },
    Audio: class { play() { return Promise.resolve(); } pause() {} },
    URL:{revokeObjectURL() {}},
    played, ended, prefetched
  });
  // Exercise the actual content-script queue; replace only DOM/audio output.
  const source = fs.readFileSync(path.join(__dirname, '../content.js'), 'utf8');
  vm.runInContext(source.replace(/\}\)\(\);\s*$/, `
    if (!${realAudio}) playNextAudio = (id, item) => {
      played.push(item.index);
      state.currentAudio = {};
      state.playbackStarted = true;
    };
    handleNarrationEnded = () => {
      ended.push(true);
      if (${completionRace}) {
        state.activeSession = {el:'next'};
        state.activeEl = 'next';
        state.playbackId += 1;
      }
    };
    startPrefetch = el => prefetched.push({el, activeEl:state.activeEl});
    updateHighlightForIndex = () => {};
    applyHighlightWordFocus = () => {};
    startHighlightWordFocusLoop = () => {};
    updateControls = () => {};
    createAudioUrl = text => text;
    globalThis.queueTest = {state, maybeStartPlayback, skipSentence, playPreviousSentence, togglePause, currentNavigationIndex, enqueueAudio, handleSessionMessage, stopNativeNarration, rememberPlayed, trimStreamHistory, activateSession, handleSessionDisconnect};
  })();`), context);
  const {state, maybeStartPlayback} = context.queueTest;
  state.playbackId = 1;
  state.activeEl = {};
  return {state, streamContext, start:()=>maybeStartPlayback(1), played, ended, timers, prefetched, ...context.queueTest};
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

test('content keeps all PCM blocks in one sentence player and skip suppresses late blocks', async () => {
  const {state, handleSessionMessage, skipSentence, stopNativeNarration} = setup(true);
  const session = {utteranceId:'stream', sourceText:'word next ' + 'x'.repeat(90), active:true, playbackId:1, streams:new Map(), audioQueue:state.audioQueue};
  state.activeSession=session;
  const pcm = Buffer.alloc(24000 * 4).toString('base64');
  const message = {type:'audio',stream:true,index:0,pieceIndex:0,sampleRate:24000,samples:24000,audioBase64:pcm,location:0,length:100,rate:1,wordTimings:[{location:0,length:4,start:0,end:0.8}]};
  handleSessionMessage(session, message); await Promise.resolve();
  const first=state.currentAudio;
  handleSessionMessage(session, {...message,pieceIndex:1,wordTimings:[{location:5,length:4,start:1,end:1.8}]});
  assert.equal(state.currentAudio,first); assert.equal(first.buffers.length,2); assert.equal(state.audioQueue.length,0);
  skipSentence();
  handleSessionMessage(session,{...message,pieceIndex:2});
  assert.equal(state.currentAudio,null); assert.equal(first.playing,false);
  handleSessionMessage(session,{type:'audio_end',index:0,chunks:3});
  handleSessionMessage(session,{...message,index:1}); await Promise.resolve();
  assert.notEqual(state.currentAudio,first);
  stopNativeNarration();
  assert.equal(first.disposed,true);
});

test('finished sentences return exactly one queue slot and old replay audio is released', () => {
  const {state,rememberPlayed,trimStreamHistory}=setup(true), sent=[], freed=[];
  state.activeSession={port:{postMessage:m=>sent.push(m)},streams:new Map()};
  for(let i=0;i<6;i++) {
    const item={index:i,url:`stream:${i}`,stream:{finished:true,dispose:()=>freed.push(i)}};
    state.activeSession.streams.set(i,item);rememberPlayed(item);rememberPlayed(item);
  }
  trimStreamHistory();
  assert.deepEqual(sent.map(m=>m.index),[0,1,2,3,4,5]);
  assert.deepEqual(freed,[0,1,2,3]);
  assert.equal(state.playedHistory.length,2); assert.equal(state.activeSession.streams.size,2);
});

function paragraphSetup(passages = null) {
  const api=setup(true), sent=[];
  const text='First sentence here. Second sentence here. Third sentence here. Fourth sentence here.';
  passages ??= [{start:0,end:text.length}];
  const session={utteranceId:'paragraph',active:true,playbackId:1,streams:new Map(),audioQueue:api.state.audioQueue,
    sourceText:text,sentenceRanges:passages,navigationTargets:require('../sentence').buildNavigationTargets(text,passages),
    nativeEnded:false,port:{postMessage:message=>sent.push(message),disconnect(){}}};
  api.state.activeSession=session;
  api.state.currentSentenceRanges=passages;
  const pcm=Buffer.alloc(24000*4).toString('base64');
  function append(index, pieceIndex, words) {
    api.handleSessionMessage(session,{type:'audio',stream:true,index,pieceIndex,sampleRate:24000,samples:24000,audioBase64:pcm,
      location:passages[index].start,length:passages[index].end-passages[index].start,rate:1,wordTimings:words});
  }
  function word(sentenceIndex, start, passageIndex=0) {
    return {location:session.navigationTargets[sentenceIndex].start-passages[passageIndex].start,length:5,start,end:start+.2};
  }
  return {...api,session,sent,text,append,word};
}

test('sentence buttons seek inside a paragraph without consuming or regenerating its stream',async()=>{
  const api=paragraphSetup();const {state,session,append,word,sent}=api;
  append(0,0,[word(0,0),word(1,.6)]);append(0,1,[word(2,1.2),word(3,1.6)]);
  api.handleSessionMessage(session,{type:'audio_end',index:0,chunks:2});await Promise.resolve();
  const stream=state.currentAudio;
  api.skipSentence();await Promise.resolve();assert.equal(state.currentAudio,stream);assert.equal(stream.offset,.6);
  assert.equal(api.currentNavigationIndex(),1);assert.equal(stream.focusRange.start,word(1,0).location);
  api.skipSentence();await Promise.resolve();assert.equal(stream.offset,1.2);
  api.playPreviousSentence();await Promise.resolve();assert.equal(stream.offset,.6);
  assert.equal(state.audioQueue.length,0);assert.equal(session.streams.size,1);assert.equal(sent.length,0);
  api.stopNativeNarration();assert.equal(stream.disposed,true);
});

test('unbuffered seeks wait for word timings and rapid clicks replace the pending destination',async()=>{
  const api=paragraphSetup();const {state,append,word}=api;
  append(0,0,[word(0,0)]);await Promise.resolve();
  const stream=state.currentAudio;
  api.skipSentence();assert.equal(state.currentAudio,null);assert.equal(state.pendingSentenceSeek.index,1);assert.equal(stream.playing,false);
  api.skipSentence();assert.equal(state.pendingSentenceSeek.index,2);
  api.playPreviousSentence();assert.equal(state.pendingSentenceSeek.index,1);
  append(0,1,[word(1,1.2)]);await Promise.resolve();
  assert.equal(state.pendingSentenceSeek,null);assert.equal(state.currentAudio,stream);assert.equal(stream.offset,1.2);
  api.stopNativeNarration();
});

test('pausing a pending seek prevents incoming chunks from starting playback; resume resolves it',async()=>{
  const api=paragraphSetup();const {state,append,word}=api;
  append(0,0,[word(0,0)]);await Promise.resolve();api.skipSentence();api.togglePause();
  append(0,1,[word(1,1.3)]);await Promise.resolve();
  assert.equal(state.isPaused,true);assert.equal(state.currentAudio,null);assert.equal(state.pendingSentenceSeek.index,1);
  api.togglePause();await Promise.resolve();assert.equal(state.currentAudio.offset,1.3);assert.equal(state.pendingSentenceSeek,null);
  api.skipSentence();api.stopNativeNarration();
  append(0,2,[word(2,2.1)]);assert.equal(state.pendingSentenceSeek,null);assert.equal(state.currentAudio,null);
});

test('sentence navigation crosses passage boundaries, returns one producer slot, and rewinds retained audio',async()=>{
  const text='First sentence here. Second sentence here. Third sentence here. Fourth sentence here.';
  const boundary=text.indexOf('Third');
  const api=paragraphSetup([{start:0,end:boundary},{start:boundary,end:text.length}]);
  const {state,session,append,word,sent}=api;
  append(0,0,[word(0,0),word(1,.6)]);api.handleSessionMessage(session,{type:'audio_end',index:0,chunks:1});await Promise.resolve();
  api.skipSentence();await Promise.resolve();api.skipSentence();
  assert.equal(state.pendingSentenceSeek.index,2);assert.deepEqual(sent.filter(m=>m.type==='consumed').map(m=>m.index),[0]);
  append(1,0,[word(2,.1,1),word(3,.6,1)]);await Promise.resolve();
  assert.equal(state.currentAudioItem.index,1);assert.equal(state.currentAudio.offset,.1);
  api.playPreviousSentence();await Promise.resolve();
  assert.equal(state.currentAudioItem.index,0);assert.equal(state.currentAudio.offset,.6);
  assert.deepEqual(Array.from(state.audioQueue,item=>item.index),[1]);
  api.skipSentence();await Promise.resolve();assert.equal(state.currentAudioItem.index,1);
  assert.deepEqual(sent.filter(m=>m.type==='consumed').map(m=>m.index),[0]);api.stopNativeNarration();
});

test('seeking ahead before audio arrives drains earlier passages without playing them',async()=>{
  const text='First sentence here. Second sentence here. Third sentence here. Fourth sentence here.';
  const second=text.indexOf('Second'),third=text.indexOf('Third');
  const api=paragraphSetup([{start:0,end:second},{start:second,end:third},{start:third,end:text.length}]);
  api.skipSentence();api.skipSentence();
  api.append(0,0,[api.word(0,0)]);assert.equal(api.state.currentAudio,null);
  api.append(1,0,[api.word(1,0,1)]);assert.equal(api.state.currentAudio,null);
  assert.deepEqual(api.sent.filter(m=>m.type==='consumed').map(m=>m.index),[0,1]);
  api.append(2,0,[api.word(2,0,2)]);await Promise.resolve();
  assert.equal(api.state.currentAudioItem.index,2);assert.equal(api.state.audioQueue.length,0);api.stopNativeNarration();
});

test('a completed-passage timer cannot override a later sentence seek',async()=>{
  const api=paragraphSetup();api.append(0,0,[api.word(0,0),api.word(1,.6)]);
  await Promise.resolve();api.streamContext.currentTime=1.04;api.state.currentAudio.onended();
  assert.equal(api.timers.length,1);api.playPreviousSentence();await Promise.resolve();
  const audio=api.state.currentAudio;api.timers[0]();
  assert.equal(api.state.currentAudio,audio);assert.equal(api.ended.length,0);api.stopNativeNarration();
});

test('Next after the final sentence cancels the stream and advances the paragraph',async()=>{
  const api=paragraphSetup();api.append(0,0,[api.word(0,0),api.word(1,.2),api.word(2,.4),api.word(3,.6)]);
  await Promise.resolve();api.streamContext.currentTime=.8;const stream=api.state.currentAudio;
  api.skipSentence();assert.equal(stream.disposed,true);assert.equal(api.state.activeSession,null);
  assert.equal(api.ended.length,1);assert.equal(api.state.pendingSentenceSeek,null);
});

test('a finished passage without target word alignment stops explicitly instead of guessing a seek time',async()=>{
  const api=paragraphSetup();api.append(0,0,[api.word(0,0)]);await Promise.resolve();
  const stream=api.state.currentAudio;api.skipSentence();
  api.handleSessionMessage(api.session,{type:'audio_end',index:0,chunks:1});
  assert.equal(stream.disposed,true);assert.equal(api.state.activeEl,null);assert.equal(api.state.pendingSentenceSeek,null);
});


test('late native completion prepares the next paragraph before advancing the active session', () => {
  const {state, handleSessionMessage, ended, prefetched} = setup(false, true);
  const el = state.activeEl;
  const session = {active:true, playbackId:1, el};
  state.activeSession = session;
  handleSessionMessage(session, {type:'end'});
  assert.equal(ended.length, 1);
  assert.equal(state.activeEl, 'next');
  assert.equal(prefetched.length, 1);
  assert.equal(prefetched[0].el, el);
  assert.equal(prefetched[0].activeEl, el, 'prefetch must not run against the old paragraph after advancement');
});

test('native completion during playback prepares the next paragraph without advancing early', () => {
  const {state, start, handleSessionMessage, ended, prefetched} = setup();
  const session = {active:true, playbackId:1, el:state.activeEl};
  state.activeSession = session;
  state.audioQueue.push({index:0});
  start();
  handleSessionMessage(session, {type:'end'});
  assert.equal(ended.length, 0);
  assert.equal(prefetched.length, 1);
  state.currentAudio = null;
  start();
  assert.equal(ended.length, 1);
});


test('completed generation can disconnect before playback ends and still advance', async () => {
  const api = paragraphSetup();
  api.append(0, 0, [api.word(0, 0)]);
  await Promise.resolve();
  api.handleSessionMessage(api.session, {type:'audio_end', index:0, chunks:1});
  api.handleSessionMessage(api.session, {type:'end'});
  api.session.port.postMessage = () => { throw new Error('Attempting to use a disconnected port object'); };
  api.handleSessionDisconnect(api.session);
  const stream = api.state.currentAudio;
  api.streamContext.currentTime = 2;
  for (const source of [...stream.sources]) source.node.onended();
  for (const timer of api.timers) timer();
  assert.equal(api.state.activeEl !== null, true, 'completion must not clear the paragraph as an error');
  assert.equal(api.ended.length, 1, 'advance after the last buffered audio ends');
  assert.equal(api.state.playedHistory.length, 1);
});

test('fully generated prefetch activates without sending to its closed producer', () => {
  const api = paragraphSetup();
  const el = api.state.activeEl;
  api.session.nativeEnded = true;
  api.session.port.postMessage = () => { throw new Error('Attempting to use a disconnected port object'); };
  api.activateSession(api.session, 2, el);
  assert.equal(api.state.activeSession, api.session);
  assert.equal(api.state.nativeEnded, true);
});


test('disconnect before generation completes still stops with an error', () => {
  const api = paragraphSetup();
  api.handleSessionDisconnect(api.session);
  assert.equal(api.state.activeSession, null);
  assert.equal(api.state.activeEl, null);
  assert.equal(api.ended.length, 0);
});
