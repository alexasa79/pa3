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
  const content=scripts.pop().replace(/\}\)\(\);\s*$/,`globalThis.mathTest={getFullText,buildNarrationPayload,getCandidates,getNextCandidate,highlightSentence,clearHighlight,applyHighlightWordFocus,startNarration,stopNarration,state};})();`);
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
    api.highlightSentence(formula,{start:3,end:3+api.getFullText(formula).length});
    const formulaOnly={text:api.state.currentHighlightEntries.map(e=>e.text ?? e.span.textContent).join(''),
      intact:formula.innerHTML===formulaOriginal, words:api.state.currentWordEntries.length};
    api.clearHighlight();
    api.state.currentHighlightTextOffset=0;
    return {texts,jobs,highlights,formulaOnly};
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const {texts,jobs,highlights,formulaOnly}=result.result.value;
  const expected='The goal of this problem is to find the minimum largest subarray sum with m subarrays. Instead of finding the answer directly, what if we try to guess the answer (say X), and check whether this particular value could be the largest subarray sum with m subarrays. If this is possible, we can check all values for X≥0, and the first value that satisfies the condition will be the answer. Thus, by repeatedly solving the following problem, we can find the minimum largest subarray sum needed to split nums into m subarrays:';
  assert.equal(texts.leetcode,expected,'Retain all five formulas in the reported paragraph');
  assert.equal(texts.dual,'Use X is greater than or equal to 0 as the condition. This sentence follows the formula.','Read MathML once, without its rendered copy or TeX annotations');
  assert.equal(texts.hidden,'Keep visible prose only.','Do not expose hidden ancestors, descendants, or unrelated elements');
  assert.equal(texts['no-aria'],'Without aria attributes: X.');
  assert.equal(jobs.length,4);
  assert.equal(jobs.map(job=>job.text).join(' '),expected);
  for(const job of jobs) assert.equal(job.text,expected.slice(job.location,job.location+job.length));
  assert.equal(highlights.reduce((sum,item)=>sum+item.mathCount,0),6);
  for(const check of highlights) {
    assert.equal(check.highlightedText,check.sentenceText);
    for(const field of ['mathIntact','heightStable','textStable','entriesValid','mathVisible','restored']) assert.equal(check[field],true,field);
  }
  assert.deepEqual(formulaOnly,{text:'X is greater than or equal to 0',intact:true,words:1});
  console.log('PASS: LeetCode KaTeX extraction, duplicate MathML exclusion, comparison pronunciation, hidden content and intact formula highlights.');
}

export async function checkMathVariants(call) {
  const fixture=await readFile(new URL('./fixtures/math-variants.html',import.meta.url),'utf8');
  const result=await call('Runtime.evaluate',{expression:`(() => {
    const holder=document.createElement('div');holder.innerHTML=${JSON.stringify(fixture)};document.body.appendChild(holder);
    const root=holder.querySelector('#math-variants'), api=mathTest;
    const candidates=api.getCandidates().filter(el=>root.contains(el));
    const checks=[];
    for(const el of root.querySelectorAll('[data-expected]')) {
      const expected=el.dataset.expected, original=el.innerHTML, text=api.getFullText(el);
      const payload=api.buildNarrationPayload(el), prefix=el.dataset.prefix || '';
      if (!payload) throw Error(el.id+' produced no narration payload');
      const ranges=ReedahSentence.buildSentenceRanges(payload.text);
      const sentences=ReedahSentence.buildSentenceRanges(text).map(s=>text.slice(s.start,s.end));
      api.state.currentHighlightTextOffset=payload.highlightTextOffset;
      const rect=el.getBoundingClientRect();
      const mathRoots=el.matches(ReedahMathNarration.ROOT_SELECTOR) ? [el]
        : [...el.querySelectorAll(ReedahMathNarration.ROOT_SELECTOR)].filter(node=>!node.parentElement.closest(ReedahMathNarration.ROOT_SELECTOR));
      const originalMath=mathRoots.map(node=>node.outerHTML);
      const spans=[];
      for(const sentence of ranges) {
        if (sentence.end<=prefix.length) continue; // Spoken list marker has no DOM text.
        api.highlightSentence(el,sentence);
        for (const progress of [0,0.5,1]) api.applyHighlightWordFocus(progress);
        spans.push({text:api.state.currentHighlightEntries.map(entry=>entry.text ?? entry.span.textContent).join(''),
          expected:payload.text.slice(Math.max(prefix.length,sentence.start),sentence.end),
          intact:mathRoots.every((node,i)=>node.outerHTML===originalMath[i]),
          stableText:api.getFullText(el)===text,
          stableHeight:Math.abs(el.getBoundingClientRect().height-rect.height)<0.1,
          words:api.state.currentWordEntries.length,
          offsets:api.state.currentWordEntries.every(entry=>entry.startOffset>=0 && entry.endOffset<=sentence.end-sentence.start)});
        api.clearHighlight();
      }
      api.state.currentHighlightTextOffset=0;
      const jobs=ReedahNativeRequestBuilder.buildSentenceJobs(payload.text,ranges);
      checks.push({id:el.id,text,expected,spans,restored:el.innerHTML===original,
        payloadValid:payload.text===prefix+text && payload.highlightTextOffset===prefix.length,
        sentences,expectedSentences:el.dataset.sentences ? JSON.parse(el.dataset.sentences) : null,
        jobTexts:jobs.map(job=>job.text),
        expectedJobTexts:el.dataset.jobTexts ? JSON.parse(el.dataset.jobTexts) : ranges.map(s=>payload.text.slice(s.start,s.end)),
        jobsValid:jobs.length===ranges.length && jobs.every((job,i)=>job.location===ranges[i].start && job.length===ranges[i].end-ranges[i].start)});
    }
    const errors=[], failures=[], log=console.error, connect=chrome.runtime.connect;
    let nativeConnections=0;
    try {
      chrome.runtime.connect=()=>{nativeConnections++;throw Error('Unexpected native connection for failed math: '+api.state.activeEl?.id);};
      console.error=(...args)=>errors.push(args.map(arg=>arg?.message ?? String(arg)).join(' '));
      for(const el of root.querySelectorAll('[data-error]')) {
        const before=errors.length;
        const payload=api.buildNarrationPayload(el);
        api.startNarration(el);
        failures.push({id:el.id,payload,stopped:api.state.activeEl===null && api.state.activeSession===null,
          logged:errors.slice(before).some(message=>message.includes(el.dataset.error))});
      }
    } finally { console.error=log;chrome.runtime.connect=connect; }
    return {checks,failures,nativeConnections,candidates:candidates.map(el=>el.id),
      expectedCandidates:[...root.querySelectorAll('[data-expected], [data-error]')].map(el=>el.id),
      next:candidates.map(el=>api.getNextCandidate(el)?.id ?? null)};
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const {checks,failures,nativeConnections,candidates,expectedCandidates,next}=result.result.value;
  assert.equal(nativeConnections,0,'Play must not open a native session for a failed formula');
  assert.deepEqual(candidates,expectedCandidates,'Every paragraph or standalone formula gets exactly one reading-order entry');
  assert.deepEqual(next,[...expectedCandidates.slice(1),null]);
  for(const check of checks) {
    assert.equal(check.text,check.expected,check.id);
    assert.equal(check.restored,true,check.id+' markup restored');
    assert.equal(check.jobsValid,true,check.id+' model text and offsets');
    assert.equal(check.payloadValid,true,check.id+' list marker and highlight prefix');
    assert.deepEqual(check.jobTexts,check.expectedJobTexts,check.id+' original terms forwarded for PA3 pronunciation');
    if (check.expectedSentences) assert.deepEqual(check.sentences,check.expectedSentences,check.id+' sentence boundaries');
    assert.ok(check.spans.length>0,check.id+' highlighted');
    for(const span of check.spans) {
      assert.equal(span.text,span.expected,check.id+' sentence range');
      for(const field of ['intact','stableText','stableHeight','offsets']) assert.equal(span[field],true,check.id+' '+field);
      assert.ok(span.words>0,check.id+' word focus');
    }
  }
  for(const failure of failures) {
    assert.equal(failure.payload,null,failure.id+' must stop without a partial request');
    assert.equal(failure.stopped,true,failure.id+' Play clears active narration');
    assert.equal(failure.logged,true,failure.id+' actionable console error');
  }
  console.log('PASS: '+checks.length+' math fixtures and '+failures.length+' rejected formulas: native MathML, KaTeX, MathJax 2/3/4, Wikimedia, Unicode offsets, list markers, original terms, highlights and no native request on failure.');
}

export async function checkMathUpdates(call) {
  const result=await call('Runtime.evaluate',{expression:`(() => {
    const api=mathTest, el=document.createElement('p');
    el.innerHTML='🙂 Read <mjx-container aria-label="x squared"><mjx-math>x²</mjx-math></mjx-container> in this expression. Then continue with the explanation.';
    document.body.appendChild(el);
    const math=el.querySelector('mjx-container'), checks=[], messages=[];
    const connect=chrome.runtime.connect;
    let connections=0;
    try {
      // Only the extension port is replaced. Play still exercises the actual
      // extraction, segmentation, native-session creation, and cleanup code.
      chrome.runtime.connect=()=>{
        connections++;
        return {onMessage:{addListener(){}},onDisconnect:{addListener(){}},
          postMessage:message=>messages.push(message),disconnect(){}};
      };
      for (const [background,color,label] of [['white','black','x squared'],['#141414','#eeeeee','fraction alpha over beta end fraction']]) {
        el.style.backgroundColor=background;el.style.color=color;
        math.setAttribute('aria-label',label);
        const original=el.innerHTML, expected='🙂 Read '+label+' in this expression. Then continue with the explanation.';
        for(let repeat=0;repeat<3;repeat++) {
          const payload=api.buildNarrationPayload(el);
          for (const sentence of ReedahSentence.buildSentenceRanges(payload.text)) {
            api.highlightSentence(el,sentence);
            api.applyHighlightWordFocus(0.5);
            checks.push({text:payload.text,expected,
              highlighted:api.state.currentHighlightEntries.map(e=>e.text ?? e.span.textContent).join(''),
              sentence:expected.slice(sentence.start,sentence.end),
              visible:math.getBoundingClientRect().width>0,
              mode:api.state.currentHighlightSpans.every(span=>span.classList.contains(background==='white' ? 'reedah-highlight-on-light' : 'reedah-highlight-on-dark'))});
            api.clearHighlight();
            checks.at(-1).restored=el.innerHTML===original;
          }
        }
        api.startNarration(el);
        api.stopNarration();
      }
      // Renderer output can change after a page loads (e.g. a streamed reply).
      // A previously valid paragraph must not keep stale speech after a failure.
      math.removeAttribute('aria-label');
      math.innerHTML='<math><menclose><mi>x</mi></menclose></math>';
      const failed=api.buildNarrationPayload(el);
      math.innerHTML='<math><msup><mi>y</mi><mn>3</mn></msup></math>';
      const recovered=api.buildNarrationPayload(el)?.text;
      return {checks,connections,starts:messages.filter(m=>m.type==='start'),failed,recovered};
    } finally { api.stopNarration();chrome.runtime.connect=connect;el.remove(); }
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const {checks,connections,starts,failed,recovered}=result.result.value;
  assert.equal(connections,2);
  assert.equal(starts.length,2);
  for (const check of checks) {
    assert.equal(check.text,check.expected);
    assert.equal(check.highlighted,check.sentence);
    for (const key of ['visible','mode','restored']) assert.equal(check[key],true,key);
  }
  assert.deepEqual(starts.map(m=>m.text),[
    '🙂 Read x squared in this expression. Then continue with the explanation.',
    '🙂 Read fraction alpha over beta end fraction in this expression. Then continue with the explanation.'
  ]);
  for (const message of starts) {
    assert.deepEqual(message.sentenceRanges,[{start:0,end:message.text.length}]);
  }
  assert.equal(failed,null);
  assert.equal(recovered,'🙂 Read y cubed in this expression. Then continue with the explanation.');
  console.log('PASS: live math updates, repeated light/dark highlight cleanup, Play request contents and recovery after renderer errors.');
}
