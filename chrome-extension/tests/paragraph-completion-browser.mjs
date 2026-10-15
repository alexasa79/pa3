import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkParagraphCompletion(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  for (const completedFirst of [false, true]) {
    await call('Page.navigate',{url:'about:blank'});
    const content=scripts.at(-1).replace(/\}\)\(\);\s*$/, 'globalThis.completionTest={enable,disable,handleSessionMessage,maybeStartPlayback,state};})();');
    const loaded=await call('Runtime.evaluate',{expression:`
      document.body.innerHTML='<main><p id="first">First paragraph.</p><p id="second">Second paragraph.</p><p id="third">Third paragraph.</p></main>';
      globalThis.requests=[];
      globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){},connect(){return {
        closed:false,onMessage:{addListener(){}},onDisconnect:{addListener(){}},
        postMessage(m){if(this.closed)throw new Error('Attempting to use a disconnected port object');requests.push(m)},
        disconnect(){this.closed=true}}}}};
    `+scripts.slice(0,-1).join('\n')+'\n'+content});
    assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
    const result=await call('Runtime.evaluate',{expression:`(async()=>{
      const api=completionTest;
      const ctx={currentTime:0,destination:{},resume:async()=>{},
        createBuffer(){return {copyToChannel(){}}},createBufferSource(){return {playbackRate:{},connect(){},disconnect(){},start(){},stop(){}}}};
      const Stream=ReedahStreamAudio.StreamAudio;
      ReedahStreamAudio.StreamAudio=class extends Stream{constructor(options){super({...options,getContext:()=>ctx})}};
      ReedahStreamAudio.unlock=async()=>{};
      api.enable();api.state.overlays.get(document.querySelector('#first')).click();
      const visited=[];
      const pcm=btoa(String.fromCharCode(...new Uint8Array(2400*4)));
      for(let i=0;i<3;i++) {
        const session=api.state.activeSession;
        visited.push(session.el.id);
        // Exercise both completion orders: producer closes before playback ends,
        // or its end message arrives after playback and pauses have drained.
        api.handleSessionMessage(session,{type:'audio',stream:true,index:0,pieceIndex:0,
          sampleRate:24000,samples:2400,audioBase64:pcm,location:0,length:session.sourceText.length,
          rate:1,wordTimings:[{location:0,length:5,start:0,end:.1}]});
        await Promise.resolve();
        api.handleSessionMessage(session,{type:'audio_end',index:0,chunks:1});
        const stream=api.state.currentAudio;
        if (${completedFirst}) {
          api.handleSessionMessage(session,{type:'end'});
          session.port.disconnect();
        }
        ctx.currentTime+=1;
        for(const source of [...stream.sources])source.node.onended();
        await new Promise(resolve=>setTimeout(resolve,${completedFirst ? 1000 : 550}));
        api.state.pendingLeadOut=false;
        if (!${completedFirst}) api.handleSessionMessage(session,{type:'end'});
      }
      const starts=requests.filter(m=>m.type==='start').map(m=>m.text);
      const idle=api.state.activeEl===null;
      api.disable();return {visited,starts,idle};
    })()`,awaitPromise:true,returnByValue:true});
    assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
    assert.deepEqual(result.result.value,{visited:['first','second','third'],
      starts:['First paragraph.','Second paragraph.','Third paragraph.'],idle:true});
    console.log('PASS: '+(completedFirst?'closed producer':'delayed completion')+' advances three paragraphs once each without duplicate prefetch requests.');
  }
}
