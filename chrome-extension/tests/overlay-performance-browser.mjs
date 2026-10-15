import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
export async function checkOverlayPerformance(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  await call('Page.navigate',{url:'about:blank'});
  const content=scripts.pop().replace(/\}\)\(\);\s*$/, `
    let checks=0;const original=isCandidate;
    isCandidate=el=>{checks++;return original(el)};
    globalThis.performanceTest={enable,disable,state,updatePositions,findCandidateByHoverBox,
      reset(){checks=0},checks:()=>checks};
  })();`);
  const loaded=await call('Runtime.evaluate',{expression:`
    document.body.innerHTML='<main>'+Array.from({length:100},(_,i)=>'<p id="p'+i+'">'+
      '<span>Readable paragraph text. </span>'.repeat(40)+'</p>').join('')+'</main>';
    globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){}}};
  `+scripts.join('\n')+'\n'+content});
  assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
  const result=await call('Runtime.evaluate',{expression:`(()=>{
    const api=performanceTest;api.enable();api.state.hoveredEl=document.querySelector('#p0');
    api.reset();const started=performance.now();api.updatePositions();
    const positioning={checks:api.checks(),ms:performance.now()-started};
    api.reset();api.findCandidateByHoverBox(-10000,-10000);
    const missChecks=api.checks();
    const overlayCount=api.state.overlays.size;api.disable();
    return {positioning,missChecks,overlayCount,remaining:document.querySelectorAll('.reedah-overlay').length};
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const data=result.result.value;
  console.log('Overlay workload:',JSON.stringify(data));
  assert.equal(data.overlayCount,100);assert.equal(data.remaining,0);
  assert.ok(data.positioning.checks<=2,'positioning must not validate hidden paragraphs');
  assert.equal(data.missChecks,0,'off-page hover must not validate paragraph contents');
}
