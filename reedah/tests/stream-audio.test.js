const test = require('node:test');
const assert = require('node:assert/strict');
const {StreamAudio, AudioBudget} = require('../stream_audio');
function setup(options = {}) {
  const nodes = [];
  const ctx = {currentTime:0, destination:{}, resume:async()=>{},
    createBuffer(channels, count, rate) { return {duration:count/rate, copyToChannel() {}}; },
    createBufferSource() {
      const node = {playbackRate:{value:1}, connect() {}, disconnect() {},
        start(when, offset) { this.when=when; this.offset=offset; }, stop() { this.stopped=true; }};
      nodes.push(node); return node;
    }};
  return {ctx, nodes, audio:new StreamAudio({getContext:()=>ctx, ...options})};
}
function chunk(index, samples=24000) {
  const data=Buffer.alloc(samples*4);
  for (let i=0;i<samples;i++) data.writeFloatLE(0.1,i*4);
  return {pieceIndex:index, samples, sampleRate:24000, audioBase64:data.toString('base64')};
}
test('PCM begins before completion and later blocks are scheduled with no gap', async () => {
  const {audio, ctx, nodes}=setup();
  audio.append(chunk(0)); await audio.play();
  assert.equal(nodes.length,1);
  ctx.currentTime=0.2; audio.append(chunk(1));
  assert.equal(nodes[1].when, nodes[0].when + 1);
  assert.equal(nodes[1].offset,0);
  audio.finish(2);
  let ended=0; audio.onended=()=>ended++;
  nodes[0].onended(); assert.equal(ended,0);
  ctx.currentTime=2.04; nodes[1].onended(); assert.equal(ended,1);
  assert.equal(audio.currentTime,2);
  audio.dispose();
});
test('pause/resume retains exact position and schedules new arrivals only on resume', async () => {
  const {audio,ctx,nodes}=setup(); audio.append(chunk(0)); await audio.play();
  ctx.currentTime=0.54; audio.pause(); assert.equal(audio.currentTime,0.5);
  audio.append(chunk(1)); assert.equal(nodes.length,1); assert.equal(nodes[0].stopped,true);
  ctx.currentTime=10; await audio.play();
  assert.equal(nodes[1].offset,0.5);
  assert.equal(nodes[2].when,nodes[1].when+0.5);
  audio.dispose();
});
test('playback speed scales scheduling and pause position', async () => {
  const {audio,ctx,nodes}=setup(); audio.playbackRate=2;
  audio.append(chunk(0)); audio.append(chunk(1)); await audio.play();
  assert.equal(nodes[1].when,nodes[0].when+audio.buffers[0].pcm.length/24000);
  assert.equal(nodes[0].playbackRate.value,1);
  ctx.currentTime=0.29; audio.pause();
  assert.ok(Math.abs(audio.currentTime-0.5)<1e-8); audio.dispose();
});
test('underrun waits for new audio without advancing or declaring sentence complete', async () => {
  const {audio,ctx,nodes}=setup(); audio.append(chunk(0)); await audio.play();
  let ended=0; audio.onended=()=>ended++;
  ctx.currentTime=5; nodes[0].onended();
  assert.equal(audio.currentTime,1); assert.equal(ended,0);
  audio.append(chunk(1)); assert.equal(nodes[1].when,5);
  audio.finish(2); ctx.currentTime=6; nodes[1].onended(); assert.equal(ended,1); audio.dispose();
});
test('cancellation while resume is pending cannot start late audio', async () => {
  const {audio,ctx,nodes}=setup(); let resume;
  ctx.resume=()=>new Promise(resolve=>resume=resolve);
  audio.append(chunk(0)); const playing=audio.play(); audio.dispose(); resume(); await playing;
  assert.equal(nodes.length,0);
});
test('replaying a sentence starts at the beginning; stale callbacks cannot finish it', async () => {
  const {audio,ctx,nodes}=setup(); audio.append(chunk(0)); audio.finish(1); await audio.play();
  const stale=nodes[0].onended; ctx.currentTime=0.5; audio.rewind();
  let ended=0; audio.onended=()=>ended++; await audio.play(); stale();
  assert.equal(nodes[1].offset,0); assert.equal(ended,0); audio.dispose();
});
test('malformed PCM, missing chunks, nonfinite samples and late data fail explicitly', () => {
  const {audio}=setup();
  assert.throws(()=>audio.append(chunk(1)), /order/);
  assert.throws(()=>audio.append({...chunk(0),samples:1}), /Truncated/);
  const invalid=Buffer.alloc(4); invalid.writeFloatLE(NaN);
  assert.throws(()=>audio.append({...chunk(0,1),audioBase64:invalid.toString('base64')}), /sample/);
  audio.append(chunk(0)); assert.throws(()=>audio.finish(2), /Incomplete/);
  audio.finish(1); assert.throws(()=>audio.append(chunk(1)), /closed/); audio.dispose();
});

test('resume after starvation then final completion advances exactly once', async () => {
  for (const finishWhilePaused of [false,true]) {
    const {audio,ctx,nodes}=setup(); audio.append(chunk(0)); await audio.play();
    ctx.currentTime=2; nodes[0].onended(); audio.pause();
    let ended=0; audio.onended=()=>ended++;
    if (finishWhilePaused) audio.finish(1);
    await audio.play();
    if (!finishWhilePaused) audio.finish(1);
    assert.equal(ended,1); assert.equal(audio.playing,false);
    assert.equal(nodes.length,1); audio.dispose();
  }
});
test('multiple resume promises and late callbacks cannot duplicate playback', async () => {
  const {audio,ctx,nodes}=setup(); const resumes=[];
  ctx.resume=()=>new Promise(resolve=>resumes.push(resolve));
  audio.append(chunk(0)); const first=audio.play(); audio.pause(); const second=audio.play();
  resumes[1](); await second; resumes[0](); await first;
  assert.equal(nodes.length,1); audio.dispose();
});
test('shared memory budget includes retained PCM and scheduled copies and releases on stop', async () => {
  const budget=new AudioBudget(96000*3);
  const one=setup({budget}), two=setup({budget});
  one.audio.append(chunk(0)); await one.audio.play();
  two.audio.append(chunk(0));
  assert.equal(budget.used,budget.limit);
  assert.throws(()=>two.audio.append(chunk(1)), /memory limit/);
  one.audio.dispose(); two.audio.dispose(); assert.equal(budget.used,0);
});
test('hundreds of replay/pause/dispose cycles leave no retained audio', async () => {
  const budget=new AudioBudget();
  for (let i=0;i<200;i++) {
    const {audio,ctx,nodes}=setup({budget}); audio.append(chunk(0,2400)); audio.finish(1);
    await audio.play(); ctx.currentTime=0.06; audio.pause(); await audio.play();
    nodes.at(-1).onended(); audio.dispose();
    assert.equal(budget.used,0);
  }
});
test('suspended audio clock does not skip samples when resumed after sleep', async () => {
  const {audio,ctx,nodes}=setup(); audio.append(chunk(0)); await audio.play();
  ctx.currentTime=0.54; const position=audio.currentTime;
  // A suspended AudioContext freezes currentTime regardless of wall-clock time.
  assert.equal(audio.currentTime,position);
  audio.append(chunk(1)); assert.equal(nodes[1].when,1.04);
  ctx.currentTime=1.54; assert.equal(audio.currentTime,1.5); audio.dispose();
});

test('Web Audio allocation failure releases the scheduled memory reservation',async()=>{
  const budget=new AudioBudget(), {audio,ctx}=setup({budget});
  audio.append(chunk(0));ctx.createBuffer=()=>{throw new Error('Allocation failed');};
  await assert.rejects(audio.play(),/Allocation failed/);audio.dispose();assert.equal(budget.used,0);
});
test('context interruption reports waiting, recovery reports playing and closure reports failure',async()=>{
  const {audio,ctx}=setup();let change,waiting=0,playing=0,errors=0;
  ctx.addEventListener=(event,fn)=>change=fn;ctx.removeEventListener=()=>{};
  audio.onwaiting=()=>waiting++;audio.onplaying=()=>playing++;audio.onerror=()=>errors++;
  audio.append(chunk(0));await audio.play();
  ctx.state='interrupted';change();assert.equal(waiting,1);assert.equal(audio.waiting,true);
  ctx.state='running';change();assert.equal(playing,1);assert.equal(audio.waiting,false);
  ctx.state='closed';change();assert.equal(errors,1);audio.dispose();
});
