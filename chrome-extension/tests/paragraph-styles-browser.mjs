import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkParagraphStyles(call) {
  const manifest = JSON.parse(await readFile(new URL('../manifest.json', import.meta.url), 'utf8'));
  const scripts = await Promise.all(manifest.content_scripts[0].js.map(file => readFile(new URL('../' + file, import.meta.url), 'utf8')));
  const fixture = await readFile(new URL('./fixtures/paragraph-styles.html', import.meta.url), 'utf8');
  await call('Page.navigate', {url: 'about:blank'});
  await call('Runtime.evaluate', {expression: `document.open(); document.write(${JSON.stringify(fixture)}); document.close();`});
  const content = scripts.pop().replace(/\}\)\(\);\s*$/, `globalThis.stylesTest={enable,disable,scanParagraphs,getCandidates,getNextCandidate,getPreviousCandidate,getFullText,highlightSentence,clearHighlight,updatePositions,state};})();`);
  const setup = `globalThis.requests=[]; globalThis.chrome={runtime:{
    onMessage:{addListener(){}}, sendMessage(){},
    connect(){return {onMessage:{addListener(){}},onDisconnect:{addListener(){}},
      postMessage(message){requests.push(message)},disconnect(){}};}
  }};`;
  const loaded = await call('Runtime.evaluate', {expression: setup + scripts.join('\n') + '\n' + content});
  assert.ok(!loaded.exceptionDetails, JSON.stringify(loaded.exceptionDetails));
  const result = await call('Runtime.evaluate', {expression: `(async () => {
    const api=stylesTest, root=document.querySelector('#matrix');
    const original=root.innerHTML;
    const heights=[...root.children].map(el=>el.getBoundingClientRect().height);
    api.enable();
    const normalize=text=>text.replace(/\\s+/g,' ').trim();
    const cases=[...root.querySelectorAll('[data-case]')].map(group=>{
      const candidates=api.getCandidates().filter(el=>group.contains(el));
      return {name:group.dataset.case,expected:JSON.parse(group.dataset.expected),
        actual:candidates.map(el=>normalize(api.getFullText(el))),
        controls:candidates.every(el=>api.state.overlays.has(el))};
    });
    const candidates=api.getCandidates();
    const order=candidates.every((el,i)=>api.getNextCandidate(el)===(candidates[i+1] ?? null)
      && api.getPreviousCandidate(el)===(candidates[i-1] ?? null));
    const stableLayout=[...root.children].every((el,i)=>Math.abs(el.getBoundingClientRect().height-heights[i])<0.1);
    const checks=candidates.map(el=>{
      const text=api.getFullText(el);
      let highlight=true;
      for(const range of ReedahSentence.buildSentenceRanges(text)) {
        api.highlightSentence(el,range);
        if(api.getFullText(el)!==text) highlight=false;
        api.clearHighlight();
      }
      const before=requests.length;
      api.state.overlays.get(el).click();
      const start=requests.slice(before).find(message=>message.type==='start');
      return {highlight,play:start?.text===text};
    });
    api.scanParagraphs(); api.scanParagraphs();
    const stableCount=api.getCandidates().length===candidates.length;
    api.disable();
    const restored=root.innerHTML===original;
    api.enable();
    const dynamic=document.createElement('div');dynamic.textContent='Dynamically inserted article prose.';
    root.appendChild(dynamic);
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const dynamicFound=api.getCandidates().some(el=>normalize(api.getFullText(el))===dynamic.textContent);
    dynamic.remove(); api.scanParagraphs();
    const dynamicRemoved=[...api.state.overlays.keys()].every(el=>el.isConnected);
    const waitForScan=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const reveal=document.querySelector('#reveal');reveal.classList.remove('gone');
    const disclosure=document.querySelector('#disclosure');disclosure.open=true;
    await waitForScan();
    const revealed=[reveal,disclosure].every(root=>[...api.state.overlays.keys()].some(el=>root===el || root.contains(el)));
    const nested=document.createElement('div');nested.textContent='Original bare text in a changing block.';
    root.appendChild(nested);await waitForScan();
    const child=document.createElement('p');child.textContent='A new semantic child in that block.';nested.appendChild(child);
    await waitForScan();
    const nestedTexts=api.getCandidates().filter(el=>nested.contains(el)).map(el=>normalize(api.getFullText(el)));
    const contents=document.querySelector('p.contents');
    contents.closest('section').scrollIntoView({behavior:'instant',block:'center'});
    api.state.hoveredEl=contents;api.updatePositions();
    const contentsControl=api.state.overlays.get(contents);
    const contentsGeometry=contentsControl?.style.display!=='none' && Number.isFinite(parseFloat(contentsControl?.style.top));
    const legacy=document.createElement('span');legacy.className='MathJax';legacy.setAttribute('aria-hidden','true');
    legacy.setAttribute('aria-label','alpha plus beta');legacy.textContent='α + β';document.body.appendChild(legacy);
    api.scanParagraphs();
    const legacyMath=api.getCandidates().includes(legacy) && api.getFullText(legacy)==='alpha plus beta';
    legacy.remove();
    api.disable();
    return {cases,order,stableLayout,checks,stableCount,restored,dynamicFound,dynamicRemoved,revealed,nestedTexts,contentsGeometry,legacyMath};
  })()`, returnByValue:true, awaitPromise:true});
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  const data=result.result.value;
  const failures=data.cases.filter(row=>JSON.stringify(row.actual)!==JSON.stringify(row.expected));
  assert.deepEqual(failures, [], 'paragraph detection matrix');
  for(const row of data.cases) assert.ok(row.controls, row.name+' controls');
  for(const check of data.checks) assert.deepEqual(check,{highlight:true,play:true});
  assert.deepEqual(data.nestedTexts,['Original bare text in a changing block.', 'A new semantic child in that block.']);
  for(const key of ['legacyMath','revealed','contentsGeometry','order','stableLayout','stableCount','restored','dynamicFound','dynamicRemoved']) assert.equal(data[key],true,key);
  console.log('PASS: '+data.cases.length+' paragraph-style cases, Play requests, highlighting, layout, deduplication, exclusions, dynamic insertion/removal and cleanup.');
}
