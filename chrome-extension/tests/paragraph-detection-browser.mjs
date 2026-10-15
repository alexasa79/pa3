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
  const content=scripts.pop().replace(/\}\)\(\);\s*$/,`globalThis.candidateTest={getCandidates,getNextCandidate,getPreviousCandidate,getFullText,highlightSentence,applyHighlightWordFocus,clearHighlight,enable,state};})();`);
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
      inlineCode:api.getFullText(document.querySelector('#recurrence')),
      narration:elements.map(el=>[el.id,api.getFullText(el).replace(/\\s+/g,' ').trim()])
    };
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const expected=['intro-heading','intro','above','left','diagonal','after-list','minimum-heading','example','explanation','recurrence-heading','recurrence','aria-paragraph','semantic-child','nested-paragraph',
    'quote-child','after-quote','bare-quote',
    '', 'mixed-quote-child', '',
    '', 'inner-quote-child','outer-quote-child',
    'first-quote-paragraph','second-quote-paragraph',
    'list-quote-intro','quoted-item','quoted-nested-item',
    '', 'quote-inside-item-child','item-after-quote','custom-quote-child','wrapped-quote-child'];
  assert.deepEqual(result.result.value.candidates,expected);
  assert.deepEqual(result.result.value.overlays,expected);
  assert.deepEqual(result.result.value.next,[...expected.slice(1),null]);
  assert.deepEqual(result.result.value.previous,[null,...expected.slice(0,-1)]);
  assert.equal(result.result.value.text,'A square of size k needs three neighboring squares:');
  assert.equal(result.result.value.inlineCode,'Store the result in dp[i][j].');
  assert.deepEqual(result.result.value.narration.slice(14).map(([,text])=>text),[
    'A quoted paragraph should be narrated exactly once.',
    'Reading continues after the quotation.',
    'A quotation can contain inline text without a paragraph element.',
    'Opening quotation text.',
    'The quotation continues in a paragraph.',
    'Closing quotation text.',
    'Outer quotation text.',
    'Inner quotation text.',
    'More outer quotation text.',
    'First paragraph of the quotation.',
    'Second paragraph of the quotation.',
    'Quoted list introduction.',
    'First quoted item.',
    'Nested quoted item.',
    'A list item introduces a quote.',
    "The list item's quotation.",
    'An independently narrated nested item.',
    'A custom paragraph inside a quotation.',
    'A quotation inside a custom wrapper.'
  ]);
  const spoken=result.result.value.narration.map(([,text])=>text).join(' ');
  for(const phrase of ['A quoted paragraph should be narrated exactly once.','Inner quotation text.','First paragraph of the quotation.','Second paragraph of the quotation.','Nested quoted item.',"The list item's quotation.",'A custom paragraph inside a quotation.','A quotation inside a custom wrapper.']) {
    assert.equal(spoken.split(phrase).length-1,1,`Narrated once: ${phrase}`);
  }
  console.log('PASS: paragraph and quotation overlays, reading order, nested quote/list deduplication, complete quote text and excluded content.');
}
