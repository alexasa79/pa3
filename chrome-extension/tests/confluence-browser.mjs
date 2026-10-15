import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkConfluence(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  const css=await readFile(new URL('../content.css',import.meta.url),'utf8');
  await call('Page.navigate',{url:new URL('./fixtures/confluence-live-document.html',import.meta.url).href});
  for(let i=0;i<100;i++) {
    const response=await call('Runtime.evaluate',{expression:'!!document.querySelector("#live-first")',returnByValue:true});
    if(response.result.value) break;
    await new Promise(resolve=>setTimeout(resolve,25));
  }
  const content=scripts.pop().replace(/\}\)\(\);\s*$/,`globalThis.editorTest={state,enable,disable,getCandidates,getNextCandidate,getFullText,buildNarrationPayload,highlightSentence,clearHighlight,applyHighlightWordFocus,updateHighlightForIndex,startNarration,stopNarration,startPrefetch,startPrefetchedNarration,handleSessionMessage};})();`);
  const setup=`globalThis.editorMessages=[];globalThis.editorErrors=[];
    globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){},connect(){return {
      onMessage:{addListener(){}},onDisconnect:{addListener(){}},
      postMessage:message=>editorMessages.push(message),disconnect(){}};}}};
    console.error=(...args)=>editorErrors.push(args.map(arg=>arg?.message ?? String(arg)).join(' '));`;
  const loaded=await call('Runtime.evaluate',{expression:setup+scripts.join('\n')+`;
    // Exercise the real DOM policy with a supplied Confluence location; the
    // fixture stays offline. Host/path restrictions have separate unit tests.
    const realEditorRootFor=ReedahEditorNarration.rootFor;
    ReedahEditorNarration.rootFor=el=>realEditorRootFor(el,{hostname:'test.atlassian.net',pathname:'/wiki/spaces/TEST/pages/1/Live'});
  `+content});
  assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
  const result=await call('Runtime.evaluate',{expression:`(async () => {
    const api=editorTest, root=document.querySelector('#ak-editor-textarea');
    const style=document.createElement('style');style.textContent=${JSON.stringify(css)};document.head.appendChild(style);
    const settle=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const original=root.innerHTML;
    const textNodes=[];const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
    while(walker.nextNode()) textNodes.push(walker.currentNode);
    const edits=[];const observer=new MutationObserver(records=>edits.push(...records));
    observer.observe(root,{subtree:true,childList:true,characterData:true,attributes:true});
    const p=document.querySelector('#live-first');
    const caret=document.createRange();caret.setStart(p.firstChild,3);caret.collapse(true);
    const selection=getSelection();selection.removeAllRanges();selection.addRange(caret);
    const selectionNode=selection.anchorNode, selectionOffset=selection.anchorOffset;
    const foreign=new Highlight(caret);CSS.highlights.set('confluence-selection',foreign);
    api.enable();await settle();
    const candidates=api.getCandidates();
    const detection={ids:candidates.map(el=>el.id),overlays:[...api.state.overlays.keys()].map(el=>el.id),
      next:candidates.map(el=>api.getNextCandidate(el)?.id ?? null),
      cursor:api.getFullText(document.querySelector('#live-cursor')),
      list:api.buildNarrationPayload(document.querySelector('#live-item')),
      math:api.getFullText(document.querySelector('#live-math')),
      lineBreak:api.getFullText(document.querySelector('#live-break'))};
    const highlights=[];
    for(const el of candidates) {
      const payload=api.buildNarrationPayload(el);
      api.state.currentHighlightTextOffset=payload.highlightTextOffset;
      for(const sentence of ReedahSentence.buildSentenceRanges(payload.text)) {
        api.highlightSentence(el,sentence);
        const light=api.state.editorHighlight;
        if(!light) throw Error('No custom highlight for '+el.id);
        const positions=[0,0.5,1].map(progress=>{
          api.applyHighlightWordFocus(progress);
          return [...light.focusHighlight].map(range=>range.toString()).join('');
        });
        highlights.push({id:el.id,ranges:light.sentenceHighlight.size,positions,
          text:[...light.sentenceHighlight].map(range=>range.toString()).join(''),
          expected:payload.text.slice(Math.max(payload.highlightTextOffset,sentence.start),sentence.end),
          intact:root.innerHTML===original,
          color:getComputedStyle(el,'::highlight(reedah-editor-sentence-light)').backgroundColor});
        api.clearHighlight();
      }
    }
    api.state.currentHighlightTextOffset=0;
    api.startNarration(p);
    api.updateHighlightForIndex(api.state.playbackId,0,0);
    api.applyHighlightWordFocus(0.65);
    api.stopNarration();
    await settle();
    const integrity={html:root.innerHTML===original,nodes:textNodes.every(node=>node.isConnected),
      mutations:edits.length,caret:selection.anchorNode===selectionNode && selection.anchorOffset===selectionOffset,
      foreign:CSS.highlights.get('confluence-selection')===foreign,
      highlights:[...CSS.highlights.keys()].filter(key=>key.startsWith('reedah-editor')).length};
    observer.disconnect();

    // Dynamic collaboration updates and node replacement with identical text.
    api.startNarration(p);api.updateHighlightForIndex(api.state.playbackId,0,0);api.applyHighlightWordFocus(0.65);
    const session=api.state.activeSession;
    const first=p.firstChild;first.replaceWith(document.createTextNode(first.nodeValue));await settle();
    const replaced={sameSession:api.state.activeSession===session,progress:api.state.editorHighlightProgress,
      usesNewNode:[...api.state.editorHighlight.sentenceHighlight].some(range=>range.startContainer===p.firstChild)};
    document.querySelector('.telepointer').textContent='Another collaborator';await settle();
    const cursorIgnored=api.state.activeSession===session;
    p.firstChild.nodeValue='The first paragraph was edited. ';await settle();
    const cancelled={active:api.state.activeEl===null,session:api.state.activeSession===null,
      highlights:[...CSS.highlights.keys()].filter(key=>key.startsWith('reedah-editor')).length,
      sentStop:editorMessages.some(message=>message.type==='stop' && message.utteranceId===session.utteranceId)};
    // A late native event must not revive a cancelled session.
    api.handleSessionMessage(session,{type:'started',utteranceId:session.utteranceId});
    cancelled.staysStopped=api.state.activeSession===null;

    api.startPrefetch(p);const prefetch=api.state.prefetchSession;
    document.querySelector('#live-cursor').appendChild(document.createTextNode(' Added content.'));await settle();
    const prefetchDiscarded=!!prefetch && api.state.prefetchSession===null && prefetch.disconnecting;
    const collapsed=document.querySelector('.ak-editor-expand__content--collapsed');collapsed.classList.remove('ak-editor-expand__content--collapsed');await settle();
    const expanded=api.state.overlays.has(document.querySelector('#live-collapsed'));
    const newP=document.createElement('p');newP.id='live-new';newP.textContent='A newly inserted live document paragraph.';root.appendChild(newP);await settle();
    const added=api.state.overlays.has(newP);
    api.startNarration(newP);const removedSession=api.state.activeSession;newP.remove();await settle();
    const removed=!api.state.overlays.has(newP) && api.state.activeSession===null && removedSession.disconnecting;

    root.style.backgroundColor='#141414';root.style.color='white';
    api.highlightSentence(p,ReedahSentence.buildSentenceRanges(api.getFullText(p))[0]);
    const dark=!!CSS.highlights.get('reedah-editor-sentence-dark');api.clearHighlight();
    // Missing API must fail before any native request, never wrap editor text.
    const highlightCtor=window.Highlight;window.Highlight=undefined;
    const before=editorMessages.length;api.startNarration(p);
    const unsupported=editorMessages.length===before && api.state.activeSession===null && editorErrors.some(e=>e.includes('CSS Custom Highlights are required'));
    window.Highlight=highlightCtor;
    api.startNarration(p);const brokenSession=api.state.activeSession;
    window.Highlight=undefined;
    api.updateHighlightForIndex(api.state.playbackId,0,0);
    const failedHighlight=api.state.activeSession===null && brokenSession.disconnecting && !root.querySelector('.reedah-highlight');
    window.Highlight=highlightCtor;
    api.disable();
    const cleanup=!document.querySelector('.reedah-overlay') && ![...CSS.highlights.keys()].some(key=>key.startsWith('reedah-editor'));
    return {detection,highlights,integrity,replaced,cursorIgnored,cancelled,prefetchDiscarded,expanded,added,removed,dark,unsupported,failedHighlight,cleanup,
      starts:editorMessages.filter(message=>message.type==='start'),errors:editorErrors};
  })()`,awaitPromise:true,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  const data=result.result.value;
  const ids=['live-heading','live-first','live-cursor','live-item','live-nested-item','live-quote','live-table','live-card','live-math','live-break'];
  assert.deepEqual(data.detection.ids,ids);
  assert.deepEqual(data.detection.overlays,ids);
  assert.deepEqual(data.detection.next,[...ids.slice(1),null]);
  assert.equal(data.detection.cursor,'Read this paragraph with 👩‍💻 intact.');
  assert.deepEqual(data.detection.list,{text:'Three. Read the outer list item once.',highlightTextOffset:7});
  assert.equal(data.detection.math,'Compute x squared without changing the equation.');
  assert.equal(data.detection.lineBreak,'Read the first line. Then read the second line.');
  for(const entry of data.highlights) {
    assert.ok(entry.ranges>0,entry.id+' range exists');
    assert.equal(entry.intact,true,entry.id+' unchanged editor');
    assert.notEqual(entry.color,'rgba(0, 0, 0, 0)',entry.id+' painted highlight');
    if(!['live-math','live-break'].includes(entry.id)) assert.equal(entry.text,entry.expected,entry.id+' exact sentence range');
  }
  const first=data.highlights.find(entry=>entry.id==='live-first');
  assert.notEqual(first.positions[0],first.positions[2],'Phrase focus follows audio');
  assert.deepEqual(data.integrity,{html:true,nodes:true,mutations:0,caret:true,foreign:true,highlights:0});
  assert.deepEqual(data.replaced,{sameSession:true,progress:0.65,usesNewNode:true});
  assert.deepEqual(data.cancelled,{active:true,session:true,highlights:0,sentStop:true,staysStopped:true});
  for(const key of ['cursorIgnored','prefetchDiscarded','expanded','added','removed','dark','unsupported','failedHighlight','cleanup']) assert.equal(data[key],true,key);
  assert.equal(data.starts[0].text,'🙂 The first sentence contains bold text and emphasis, plus type_name_t for narration. The second sentence follows without editing the document.');
  assert.deepEqual(data.starts[0].sentenceRanges,[{start:0,end:data.starts[0].text.length}]);
  assert.equal(data.errors.length,2,JSON.stringify(data.errors));
  console.log('PASS: Confluence live editor detection, exact narration, non-mutating highlights/caret, cursor filtering, edits, prefetch invalidation, node replacement, light/dark themes and cleanup.');
}
