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

test('recognized groups follow the audio clock, deduplicate expansions, and rewind', async () => {
  const {audio, ctx}=setup({sourceLength:100, playbackRate:1.1});
  const words=[{location:0,length:3,start:0,end:.2},{location:0,length:3,start:.2,end:.3},
    {location:4,length:4,start:.3,end:.5},{location:9,length:2,start:.5,end:.6},
    {location:12,length:4,start:.7,end:.9}];
  audio.append({...chunk(0),wordTimings:words});
  assert.deepEqual(audio.focusRange,{start:0,end:11});
  await audio.play(); ctx.currentTime=.8; audio.pause();
  assert.deepEqual(audio.focusRange,{start:12,end:16});
  const held=audio.focusRange; ctx.currentTime=10;
  assert.deepEqual(audio.focusRange,held);
  audio.rewind(); assert.deepEqual(audio.focusRange,{start:0,end:11}); audio.dispose();
});
test('timed streams reject absent or invalid source metadata instead of estimating progress', () => {
  for(const words of [undefined,[{location:101,length:1,start:0,end:1}],
    [{location:0,length:1,start:.8,end:.2}], [{location:0,length:1,start:0,end:2}]]) {
    const {audio}=setup({sourceLength:100});
    assert.throws(()=>audio.append({...chunk(0),wordTimings:words})); audio.dispose();
  }
});

test('focus groups restart at sentence boundaries and hold through pauses', () => {
  const {buildSentenceRanges} = require('../sentence');
  for (const text of ['One two. Three four five six seven. Eight nine!',
    '“One two!” Three four five six seven? Eight nine.',
    'Mr. Smith paid 3.14 dollars. Then he left. Goodbye!']) {
    const sentenceRanges = buildSentenceRanges(text, {minSentenceLength:0});
    const {audio} = setup({sourceLength:text.length, sentenceRanges});
    const words = [...text.matchAll(/\S+/gu)].map((match, index) => ({
      location:match.index, length:match[0].length, start:index * .3, end:index * .3 + .1
    }));
    audio.appendTimings(words, words.length * .3);
    for (let i = 0; i < words.length; i++) {
      const sentence = sentenceRanges.find(range => words[i].location >= range.start && words[i].location < range.end);
      const first = words.findIndex(word => word.location >= sentence.start);
      const groupStart = first + Math.floor((i - first) / 3) * 3;
      const group = words.slice(groupStart, groupStart + 3).filter(word => word.location < sentence.end);
      const expected = {start:group[0].location, end:group.at(-1).location + group.at(-1).length};
      audio.offset = words[i].start;
      assert.deepEqual(audio.focusRange, expected);
      // Keep the same sentence during silence, even if the next word is ready.
      audio.offset = words[i].end + .1;
      assert.deepEqual(audio.focusRange, expected);
    }
    audio.dispose();
  }
});

test('sentence focus remains bounded across streamed arrivals, seek and rewind', () => {
  const {buildSentenceRanges} = require('../sentence');
  const text = 'One two. Three four five six. Seven eight.';
  const {audio} = setup({sourceLength:text.length,
    sentenceRanges:buildSentenceRanges(text, {minSentenceLength:0})});
  const words = [...text.matchAll(/\S+/gu)].map((match, i) => ({
    location:match.index, length:match[0].length, start:i * .1, end:(i + 1) * .1
  }));
  audio.append({...chunk(0), wordTimings:words.slice(0, 2)});
  assert.deepEqual(audio.focusRange, {start:0, end:8});
  audio.append({...chunk(1), wordTimings:words.slice(2)});
  assert.deepEqual(audio.focusRange, {start:0, end:8});
  audio.seek(words[3].start);
  assert.deepEqual(audio.focusRange, {start:15, end:29});
  audio.offset = words[6].start;
  assert.deepEqual(audio.focusRange, {start:30, end:42});
  audio.rewind();
  assert.deepEqual(audio.focusRange, {start:0, end:8});
  audio.dispose();
});

test('seeking within retained paragraph audio cancels old sources and preserves speed', async () => {
  for (const speed of [0.5, 1, 1.5, 2]) {
    const budget = new AudioBudget();
    const {audio, ctx, nodes} = setup({budget, playbackRate:speed, sourceLength:60});
    audio.append({...chunk(0), wordTimings:[{location:0,length:5,start:0,end:.2},{location:20,length:6,start:.6,end:.9}]});
    audio.append({...chunk(1), wordTimings:[{location:40,length:5,start:1.2,end:1.8}]});
    audio.finish(2); await audio.play();
    const stale=nodes[0].onended;
    ctx.currentTime=.1;
    audio.seek(1.2);
    assert.equal(audio.currentTime,1.2);
    assert.equal(audio.currentSourceLocation,40);
    assert.ok(nodes.every(node=>node.stopped));
    let ended=0; audio.onended=()=>ended++;
    await audio.play(); stale(); assert.equal(ended,0);
    assert.ok(Math.abs(audio.sources[0].start-1.2)<1e-8);
    audio.seek(.6); await audio.play();
    assert.equal(audio.currentSourceLocation,20);
    assert.equal(audio.offset,.6);
    audio.dispose(); assert.equal(budget.used,0);
  }
});

test('seeking while streaming keeps accepting later chunks and rejects invalid positions', async () => {
  const {audio,ctx,nodes}=setup();audio.append(chunk(0));await audio.play();
  audio.seek(.75);await audio.play();
  audio.append(chunk(1));audio.finish(2);
  assert.equal(audio.sources[0].start,.75);
  assert.equal(audio.sources.at(-1).end,2);
  for (const position of [-1,Infinity,NaN,2.1]) assert.throws(()=>audio.seek(position),/seek/i);
  ctx.currentTime=5;let ended=0;audio.onended=()=>ended++;
  for(const source of audio.sources.slice()) source.node.onended();
  assert.equal(ended,1);audio.dispose();
  assert.throws(()=>audio.seek(0),/disposed/i);
});


test('uncertain recognition keeps audio playing, holds focus and recovers on the audio clock', async () => {
  const {audio,ctx,nodes}=setup({sourceLength:100});
  audio.append({...chunk(0),wordTimings:[]});
  await audio.play();
  assert.equal(nodes.length,1);
  assert.equal(audio.focusRange,null);
  audio.append({...chunk(1),wordTimings:[{location:10,length:4,start:1,end:1.2}]});
  assert.equal(audio.focusRange,null); // Future recognition must not advance highlighting early.
  ctx.currentTime=1.3;
  const held=audio.focusRange;
  assert.deepEqual(held,{start:10,end:14});
  audio.append({...chunk(2),wordTimings:[]});
  ctx.currentTime=2.5;
  assert.deepEqual(audio.focusRange,held);
  audio.append({...chunk(3),wordTimings:[{location:50,length:4,start:3,end:3.2}]});
  assert.deepEqual(audio.focusRange,held);
  ctx.currentTime=3.3;
  assert.equal(audio.currentSourceLocation,50);
  assert.deepEqual(audio.focusRange,{start:50,end:54});
  assert.equal(nodes.length,4);
  audio.finish(4); audio.dispose();
});
