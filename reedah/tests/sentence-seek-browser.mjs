import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkSentenceSeeking(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  await call('Page.navigate',{url:'about:blank'});
  await call('Runtime.evaluate',{expression:`document.body.innerHTML='<main><p id="spoken">First sentence here. Second sentence here. Third sentence here.</p></main>';`});
  const content=scripts.pop().replace(/\}\)\(\);\s*$/,`globalThis.seekTest={enable,disable,handleSessionMessage,state};})();`);
  const loaded=await call('Runtime.evaluate',{expression:`globalThis.requests=[];globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){},
    connect(){return {onMessage:{addListener(){}},onDisconnect:{addListener(){}},postMessage(m){requests.push(m)},disconnect(){}}}}};`
    +scripts.join('\n')+'\n'+content});
  assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
  const result=await call('Runtime.evaluate',{expression:`(async()=>{
    const api=seekTest, ctx={currentTime:0,destination:{},resume:async()=>{},
      createBuffer(){return {copyToChannel(){}}},createBufferSource(){return {playbackRate:{},connect(){},disconnect(){},start(){},stop(){}}}};
    const Stream=ReedahStreamAudio.StreamAudio;
    ReedahStreamAudio.StreamAudio=class extends Stream{constructor(options){super({...options,getContext:()=>ctx})}};
    ReedahStreamAudio.unlock=async()=>{};
    api.enable();const el=document.querySelector('#spoken');api.state.overlays.get(el).click();
    const session=api.state.activeSession,targets=session.navigationTargets;
    const pcm=btoa(String.fromCharCode(...new Uint8Array(24000*4)));
    const append=(piece,index,time)=>api.handleSessionMessage(session,{type:'audio',stream:true,index:0,pieceIndex:piece,
      sampleRate:24000,samples:24000,audioBase64:pcm,location:0,length:session.sourceText.length,rate:1,
      wordTimings:[{location:targets[index].start,length:5,start:time,end:time+.2}]});
    const next=()=>api.state.controls.skipSentence.click(),prev=()=>api.state.controls.prevSentence.click();
    append(0,0,0);await Promise.resolve();
    const first=api.state.currentAudio;
    const initial={count:targets.length,previousEnabled:!api.state.controls.prevSentence.disabled,
      nextTitle:api.state.controls.skipSentence.title,previousTitle:api.state.controls.prevSentence.title};
    next();const pending=api.state.controls.sentence.textContent;
    next();prev();append(1,1,1.1);await Promise.resolve();
    const resumed={sameStream:api.state.currentAudio===first,offset:first.offset,status:api.state.controls.sentence.textContent};
    api.state.controls.playPause.click();prev();await Promise.resolve();
    const rewound={paused:api.state.isPaused,offset:first.offset};
    next();await Promise.resolve();append(2,2,2.1);
    api.handleSessionMessage(session,{type:'audio_end',index:0,chunks:3});
    ctx.currentTime=1.2;
    await new Promise(resolve=>requestAnimationFrame(resolve));
    const clockStatus=api.state.controls.sentence.textContent;
    // All three sentences have timings now. The focus must still contain only
    // the word from the sentence selected by the audio clock.
    const focus=first.focusRange;
    const expectedFocus={start:targets[2].start,end:targets[2].start+5};
    prev();await Promise.resolve();const previousOffset=first.offset;
    const starts=requests.filter(m=>m.type==='start'),consumed=requests.filter(m=>m.type==='consumed');
    api.disable();
    return {initial,pending,resumed,rewound,clockStatus,focus,expectedFocus,previousOffset,startCount:starts.length,
      passageCount:starts[0].sentenceRanges.length,consumed:consumed.length,disposed:first.disposed};
  })()`,returnByValue:true,awaitPromise:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const data=result.result.value;
  assert.deepEqual(data.initial,{count:3,previousEnabled:true,nextTitle:'Next sentence',previousTitle:'Previous sentence'});
  assert.match(data.pending,/Buffering.*S 2\/3/);
  assert.equal(data.resumed.sameStream,true);assert.equal(data.resumed.offset,1.1);assert.match(data.resumed.status,/S 2\/3/);
  assert.deepEqual(data.rewound,{paused:false,offset:0});
  assert.match(data.clockStatus,/S 3\/3/);assert.equal(data.previousOffset,1.1);
  assert.deepEqual(data.focus,data.expectedFocus,'Streaming playback focus stays inside the current sentence');
  assert.equal(data.startCount,1);assert.equal(data.passageCount,1);assert.equal(data.consumed,0);assert.equal(data.disposed,true);
  console.log('PASS: actual sentence controls, buffering/rapid clicks, pause-and-seek, audio-clock sentence counts and no paragraph regeneration.');
}
