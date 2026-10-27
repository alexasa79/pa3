import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

export async function checkFactorioNarration(call) {
  const fixture = await readFile(new URL('./fixtures/factorio-447.html', import.meta.url), 'utf8');
  const result = await call('Runtime.evaluate', {expression:`(() => {
    const root = document.createElement('section');
    root.innerHTML = ${JSON.stringify(fixture)};
    document.body.appendChild(root);
    const results = [...root.querySelectorAll('p')].map(p => {
      const text = mathTest.getFullText(p);
      const ranges = ReedahSentence.buildSentenceRanges(text);
      const jobs = ReedahNativeRequestBuilder.buildNarrationJobs(text);
      for (const range of ranges) {
        mathTest.highlightSentence(p, range);
        if (mathTest.getFullText(p) !== text) throw Error('Highlight changed narration text');
        mathTest.clearHighlight();
      }
      return {visible:p.textContent.replace(/\\s+/g,' ').trim(), jobs};
    });
    root.remove();
    return results;
  })()`, returnByValue:true});
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  const paragraphs = result.result.value;
  assert.equal(paragraphs.length, 3);
  assert.deepEqual(paragraphs.flatMap(p => p.jobs.map(j => j.text.trim().split(/\s+/)[0])),
    ['It', 'Since', 'Being']);
  for (const paragraph of paragraphs) {
    const spoken = paragraph.jobs.map(j => j.text).join(' ').replace(/\s+/g, ' ').trim();
    assert.equal(spoken, paragraph.visible);
    assert.doesNotMatch(spoken, /<|>|href|https:/);
  }
  assert.match(paragraphs[0].jobs[0].text, /our players\./);
  assert.match(paragraphs[0].jobs[0].text, /A decision.*playtesting event \(FFF-427\),/);
  assert.match(paragraphs[0].jobs[0].text, /FFF-427/);
  console.log('PASS: Factorio sentence starts, inline link text, no HTML leakage, and stable text after highlighting.');
}
