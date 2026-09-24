import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkMathNarration(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  const builder=await readFile(new URL('../native_request_builder.js',import.meta.url),'utf8');
  const css=await readFile(new URL('../content.css',import.meta.url),'utf8');
  await call('Page.navigate',{url:new URL('./fixtures/katex-paragraphs.html',import.meta.url).href});
  for(let i=0;i<100;i++) {
    const result=await call('Runtime.evaluate',{expression:'!!document.querySelector("#no-aria")',returnByValue:true});
    if(result.result.value)break;
    await new Promise(resolve=>setTimeout(resolve,50));
  }
  const setup=`globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){}}};`;
  const content=scripts.pop().replace(/\}\)\(\);\s*$/,`globalThis.mathTest={getFullText,highlightSentence,clearHighlight,applyHighlightWordFocus,state};})();`);
  const loaded=await call('Runtime.evaluate',{expression:setup+scripts.join('\n')+'\n'+builder+'\n'+content});
  assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
  const result=await call('Runtime.evaluate',{expression:`(() => {
    const api=mathTest;
    const style=document.createElement('style');style.textContent=${JSON.stringify(css)};document.head.appendChild(style);
    const texts=Object.fromEntries(['leetcode','dual','hidden','no-aria'].map(id=>[id,api.getFullText(document.getElementById(id))]));
    const jobs=ReedahNativeRequestBuilder.buildSentenceJobs(texts.leetcode,ReedahSentence.buildSentenceRanges(texts.leetcode),[]);
    const highlights=[];
    for(const id of ['leetcode','dual']) {
      const p=document.getElementById(id), original=p.innerHTML, text=texts[id];
      const formulas=[...p.querySelectorAll('.katex')], formulaMarkup=formulas.map(el=>el.innerHTML);
      const height=p.getBoundingClientRect().height;
      for(const sentence of ReedahSentence.buildSentenceRanges(text)) {
        api.highlightSentence(p,sentence);
        api.applyHighlightWordFocus(0.5);
        const visibleMath=formulas.filter(el=>el.closest('.reedah-highlight'));
        highlights.push({
          highlightedText:api.state.currentHighlightEntries.map(entry=>entry.text ?? entry.span.textContent).join(''),
          sentenceText:text.slice(sentence.start,sentence.end),
          mathIntact:formulas.every((el,i)=>el.innerHTML===formulaMarkup[i]),
          heightStable:p.getBoundingClientRect().height===height,
          textStable:api.getFullText(p)===text,
          mathCount:visibleMath.length,
          entriesValid:api.state.currentWordEntries.every(entry=>entry.startOffset>=0 && entry.endOffset<=sentence.end-sentence.start),
          mathVisible:visibleMath.every(el=>el.getBoundingClientRect().width>0),
        });
        api.clearHighlight();
        highlights.at(-1).restored=p.innerHTML===original;
      }
    }
    // Exercise the spoken ordered-list prefix: highlight coordinates start later
    // than the DOM text, including when the sentence consists of just a formula.
    const formula=document.querySelector('#dual .katex');
    const formulaOriginal=formula.innerHTML;
    api.state.currentHighlightTextOffset=3;
    api.highlightSentence(formula,{start:3,end:6});
    const formulaOnly={text:api.state.currentHighlightEntries.map(e=>e.text ?? e.span.textContent).join(''),
      intact:formula.innerHTML===formulaOriginal, words:api.state.currentWordEntries.length};
    api.clearHighlight();
    return {texts,jobs,highlights,formulaOnly};
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const {texts,jobs,highlights,formulaOnly}=result.result.value;
  const expected='The goal of this problem is to find the minimum largest subarray sum with m subarrays. Instead of finding the answer directly, what if we try to guess the answer (say X), and check whether this particular value could be the largest subarray sum with m subarrays. If this is possible, we can check all values for X≥0, and the first value that satisfies the condition will be the answer. Thus, by repeatedly solving the following problem, we can find the minimum largest subarray sum needed to split nums into m subarrays:';
  assert.equal(texts.leetcode,expected,'Retain all five formulas in the reported paragraph');
  assert.equal(texts.dual,'Use X≥0 as the condition. This sentence follows the formula.','Read the rendered copy exactly once, without TeX annotations');
  assert.equal(texts.hidden,'Keep visible prose only.','Do not expose hidden ancestors, descendants, or unrelated elements');
  assert.equal(texts['no-aria'],'Without aria attributes: X.');
  assert.equal(jobs.length,4);
  assert.equal(jobs.map(job=>job.text).join(' '),expected.replace('X≥0','X is greater than or equal to 0'));
  for(const job of jobs) assert.equal(job.text,expected.slice(job.location,job.location+job.length).replace('X≥0','X is greater than or equal to 0'));
  assert.equal(highlights.reduce((sum,item)=>sum+item.mathCount,0),6);
  for(const check of highlights) {
    assert.equal(check.highlightedText,check.sentenceText);
    for(const field of ['mathIntact','heightStable','textStable','entriesValid','mathVisible','restored']) assert.equal(check[field],true,field);
  }
  assert.deepEqual(formulaOnly,{text:'X≥0',intact:true,words:1});
  console.log('PASS: LeetCode KaTeX extraction, duplicate MathML exclusion, comparison pronunciation, hidden content and intact formula highlights.');
}
