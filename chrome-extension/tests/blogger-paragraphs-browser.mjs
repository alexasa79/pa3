import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkBloggerParagraphs(call) {
  const manifest = JSON.parse(await readFile(new URL('../manifest.json', import.meta.url), 'utf8'));
  const scripts = await Promise.all(manifest.content_scripts[0].js.map(file => readFile(new URL('../' + file, import.meta.url), 'utf8')));
  const fixture = await readFile(new URL('./fixtures/blogger-paragraphs.html', import.meta.url), 'utf8');
  await call('Page.navigate', {url: 'about:blank'});
  await call('Runtime.evaluate', {expression: `document.open(); document.write(${JSON.stringify(fixture)}); document.close();`});
  const content = scripts.pop().replace(/\}\)\(\);\s*$/, `globalThis.bloggerTest={enable,disable,scanParagraphs,getCandidates,getNextCandidate,getPreviousCandidate,getFullText,highlightSentence,clearHighlight,state};})();`);
  const setup = `globalThis.requests=[]; globalThis.chrome={runtime:{
    onMessage:{addListener(){}}, sendMessage(){},
    connect(){return {onMessage:{addListener(){}},onDisconnect:{addListener(){}},
      postMessage(message){requests.push(message)},disconnect(){}};}
  }};`;
  const loaded = await call('Runtime.evaluate', {expression: setup + scripts.join('\n') + '\n' + content});
  assert.ok(!loaded.exceptionDetails, JSON.stringify(loaded.exceptionDetails));
  const result = await call('Runtime.evaluate', {expression: `(() => {
    const api=bloggerTest, root=document.querySelector('#article');
    const original=root.innerHTML, height=root.getBoundingClientRect().height;
    const link=document.querySelector('#original-link');
    api.enable();
    const candidates=api.getCandidates().filter(el=>root.contains(el));
    const texts=candidates.map(el=>api.getFullText(el).replace(/\\s+/g,' ').trim());
    const overlays=candidates.every(el=>api.state.overlays.has(el));
    const order=candidates.every((el,i)=>api.getNextCandidate(el)===(candidates[i+1] ?? null)
      && api.getPreviousCandidate(el)===(candidates[i-1] ?? null));
    const stableHeight=Math.abs(root.getBoundingClientRect().height-height)<0.1;
    api.scanParagraphs(); api.scanParagraphs();
    const stableCandidates=api.getCandidates().length===candidates.length;
    const highlights=candidates.every(el=>{
      const text=api.getFullText(el);
      for(const range of ReedahSentence.buildSentenceRanges(text)) {
        api.highlightSentence(el,range);
        if(api.getFullText(el)!==text) return false;
        api.clearHighlight();
      }
      return true;
    });
    api.state.overlays.get(candidates[0]).click();
    const starts=requests.filter(message=>message.type==='start');
    api.disable();
    const restored=root.innerHTML===original && document.querySelector('#original-link')===link;
    api.enable();
    const reenabled=api.getCandidates().map(el=>api.getFullText(el).replace(/\\s+/g,' ').trim());
    api.disable();
    return {texts,overlays,order,stableHeight,stableCandidates,highlights,starts,restored,reenabled};
  })()`, returnByValue: true});
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  const data = result.result.value;
  const expected = ['Opening paragraph with an inline link.', 'Second paragraph in the same container.',
    'Figure one: the chart caption.', 'Third paragraph in a generic container.', 'Figure two: another caption.',
    'Text after the nested table.', 'Existing semantic paragraph stays independent.', 'Text after a semantic paragraph.'];
  assert.deepEqual(data.texts, expected);
  assert.deepEqual(data.reenabled, expected);
  for (const key of ['overlays', 'order', 'stableHeight', 'stableCandidates', 'highlights', 'restored']) assert.equal(data[key], true, key);
  assert.equal(data.starts.length, 1);
  assert.equal(data.starts[0].text.trim(), expected[0]);
  console.log('PASS: Blogger bare text/BR/DIV paragraphs, captions, Play request, reading order, stable layout/highlighting, exclusions and toggle cleanup.');
}
