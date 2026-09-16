import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkParagraphs(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  await call('Page.navigate',{url:new URL('./fixtures/mdx-paragraphs.html',import.meta.url).href});
  for(let i=0;i<100;i++) {
    const result=await call('Runtime.evaluate',{expression:'!!document.querySelector("#recurrence")',returnByValue:true});
    if(result.result.value)break;
    await new Promise(resolve=>setTimeout(resolve,50));
  }
  const setup=`globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){}}};`;
  const content=scripts.pop().replace(/\}\)\(\);\s*$/,`globalThis.candidateTest={getCandidates,getNextCandidate,getPreviousCandidate,getFullText,highlightSentence,clearHighlight,enable,state};})();`);
  const loaded=await call('Runtime.evaluate',{expression:setup+scripts.join('\n')+'\n'+content});
  assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
  const result=await call('Runtime.evaluate',{expression:`(() => {
    const api=candidateTest;
    api.enable();
    const elements=api.getCandidates();
    return {
      candidates:elements.map(el=>el.id),
      overlays:[...api.state.overlays.keys()].map(el=>el.id),
      next:elements.map(el=>api.getNextCandidate(el)?.id ?? null),
      previous:elements.map(el=>api.getPreviousCandidate(el)?.id ?? null),
      text:api.getFullText(document.querySelector('#intro')),
      inlineCode:api.getFullText(document.querySelector('#recurrence'))
    };
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const expected=['intro-heading','intro','above','left','diagonal','after-list','minimum-heading','example','explanation','recurrence-heading','recurrence','aria-paragraph','semantic-child','nested-item'];
  assert.deepEqual(result.result.value.candidates,expected);
  assert.deepEqual(result.result.value.overlays,expected);
  assert.deepEqual(result.result.value.next,[...expected.slice(1),null]);
  assert.deepEqual(result.result.value.previous,[null,...expected.slice(0,-1)]);
  assert.equal(result.result.value.text,'A square of size k needs three neighboring squares:');
  assert.equal(result.result.value.inlineCode,'Store the result in dp[i][j].');
  console.log('PASS: MDX paragraph overlays, forward/backward reading order, inline text, wrapper deduplication and excluded content.');
}
