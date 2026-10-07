import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';

export async function checkFrames(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  const content=scripts.pop().replace(/\}\)\(\);\s*$/, 'globalThis.frameAPI={getCandidates,getFullText,enable,disable,state,FRAME_TOKEN};})();');
  const server=createServer((req,res)=>{
    res.setHeader('Content-Type','text/html');
    if(req.url==='/root')res.end(`<!doctype html><main><p>Top document paragraph.</p>
      <iframe src="/same"></iframe><iframe src="http://127.0.0.1:${other.address().port}/cross"></iframe>
      <iframe srcdoc="<main><p>Srcdoc paragraph.</p></main>"></iframe></main>`);
    else if(req.url==='/same')res.end('<!doctype html><main><ul><li><p>Same origin paragraph.</p><p>Another embedded paragraph.</p></li></ul><iframe src="/nested"></iframe></main>');
    else res.end('<!doctype html><main><p>Nested paragraph.</p></main>');
  });
  const other=createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end('<!doctype html><main><table><tr><td><p>Cross origin paragraph.</p></td></tr></table></main>');});
  await Promise.all([new Promise(resolve=>server.listen(0,'127.0.0.1',resolve)),new Promise(resolve=>other.listen(0,'127.0.0.1',resolve))]);
  // Real frame documents, origins, parser and DOM; extension messaging is stubbed,
  // as in the rest of the browser suite. Routing is independently unit tested.
  const setup=`globalThis.frameMessages=[];globalThis.frameRequests=[];
    globalThis.chrome={runtime:{
      onMessage:{addListener(fn){frameMessages.push(fn)}},
      sendMessage(message,callback){if(message.type==='reedah-frame-ready')callback?.({enabled:true});},
      connect(){return {onMessage:{addListener(){}},onDisconnect:{addListener(){}},
        postMessage(message){frameRequests.push(message)},disconnect(){}};}
    }};
    window.addEventListener('message',event=>{
      if(!['inspect','disable','stop'].includes(event.data?.testAction))return;
      if(event.data.testAction==='stop') {
        const active=frameAPI.state.activeEl;
        frameMessages.forEach(fn=>fn({type:'reedah-stop-other-frame',token:frameAPI.FRAME_TOKEN},{},()=>{}));
        const preserved=frameAPI.state.activeEl===active && active!==null;
        frameMessages.forEach(fn=>fn({type:'reedah-stop-other-frame',token:'another-frame'},{},()=>{}));
        top.postMessage({frameResult:true,preserved,stopped:frameAPI.state.activeEl===null},'*');
      } else if(event.data.testAction==='disable') {
        frameMessages.forEach(fn=>fn({type:'reedah-set-enabled',enabled:false},{},()=>{}));
        top.postMessage({frameResult:true,disabled:true,url:location.href,count:document.querySelectorAll('.reedah-overlay').length},'*');
      } else {
        const api=globalThis.frameAPI;if(!api){top.postMessage({frameResult:true,error:'missing API',url:location.href},'*');return;}
        const candidates=api.getCandidates();
        const texts=candidates.map(el=>api.getFullText(el).trim());
        if(candidates[0])api.state.overlays.get(candidates[0])?.click();
        const start=frameRequests.find(r=>r.type==='start');
        top.postMessage({frameResult:true,url:location.href,texts,enabled:api.state.enabled,play:start?.text},'*');
      }
      for(const frame of document.querySelectorAll('iframe'))frame.contentWindow.postMessage(event.data,'*');
    });
  `;
  const injected=await call('Page.addScriptToEvaluateOnNewDocument',{source:setup+scripts.join('\n')+'\n'+content});
  try {
    await call('Page.navigate',{url:'http://127.0.0.1:'+server.address().port+'/root'});
    let ready=false;
    for(let i=0;i<100;i++){
      const result=await call('Runtime.evaluate',{expression:'document.readyState==="complete" && !!globalThis.frameAPI',returnByValue:true});
      if(result.result.value){ready=true;break;}
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    assert.ok(ready,'frame fixture loaded');
    await call('Runtime.evaluate',{expression:`globalThis.frameResults=[];window.addEventListener('message',e=>{if(e.data?.frameResult)frameResults.push(e.data)});frameAPI.enable();window.postMessage({testAction:'inspect'},'*');`});
    const wait=async count=>{
      for(let i=0;i<100;i++){
        const result=await call('Runtime.evaluate',{expression:'frameResults',returnByValue:true});
        if(result.result.value?.length>=count)return result.result.value;
        await new Promise(resolve=>setTimeout(resolve,50));
      }
      throw Error('Frame reports timed out');
    };
    const results=await wait(5);
    assert.equal(results.length,5);
    assert.deepEqual(results.flatMap(r=>r.texts).sort(),[
      'Top document paragraph.','Same origin paragraph.','Another embedded paragraph.',
      'Cross origin paragraph.','Nested paragraph.','Srcdoc paragraph.'
    ].sort());
    for(const result of results){assert.equal(result.enabled,true,result.url);assert.equal(result.play,result.texts[0],result.url);}
    await call('Runtime.evaluate',{expression:"frameResults=[];window.postMessage({testAction:'stop'},'*');"});
    for(const result of await wait(5)){assert.equal(result.preserved,true);assert.equal(result.stopped,true);}
    await call('Runtime.evaluate',{expression:"frameResults=[];window.postMessage({testAction:'disable'},'*');"});
    for(const result of await wait(5)){assert.equal(result.disabled,true);assert.equal(result.count,0);}
    console.log('PASS: top, same-origin, cross-origin, srcdoc and nested iframe paragraphs, Play payloads, cross-frame stop handling and disable cleanup.');
  } finally {
    await call('Page.removeScriptToEvaluateOnNewDocument',{identifier:injected.identifier});
    await call('Page.navigate',{url:'about:blank'});
    server.closeAllConnections();
    other.closeAllConnections();
    await Promise.all([new Promise(resolve=>server.close(resolve)),new Promise(resolve=>other.close(resolve))]);
  }
}
