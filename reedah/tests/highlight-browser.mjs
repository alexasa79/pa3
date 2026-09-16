import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
export async function checkHighlights(call) {
  const css=await readFile(new URL('../content.css',import.meta.url),'utf8');
  const result=await call('Runtime.evaluate',{expression:`(() => {
    const style=document.createElement('style');style.textContent=${JSON.stringify(css)};document.head.appendChild(style);
    const api=candidateTest,results=[];
    const colors=[
      ['rgb(250, 249, 245)','light'],['rgb(30, 30, 30)','dark'],
      ['color(srgb 0.96 0.95 0.92)','light'],['color(srgb 0.12 0.12 0.12)','dark'],
      ['oklch(96% 0.02 80)','light'],['oklch(24% 0.02 80)','dark'],
      ['color(display-p3 0.95 0.93 0.9)','light'],['color(display-p3 0.1 0.1 0.1)','dark'],
      ['color-mix(in oklab, white 95%, black)','light'],
      ['color-mix(in srgb, black 95%, white)','dark']
    ];
    for(const [background,expected] of colors) {
      const section=document.createElement('section');section.style.backgroundColor=background;
      section.style.color=expected==='dark'?'white':'black';
      section.innerHTML='<p>First sentence with <strong>bold text</strong> and <code>code</code>. Next sentence.</p>';
      document.body.appendChild(section);
      const p=section.firstElementChild,original=p.innerHTML;
      const text=api.getFullText(p),end=text.indexOf('. ')+1;
      const mode=ReedahHighlightTheme.detectHighlightMode(p);
      api.highlightSentence(p,{start:0,end});
      const spans=[...p.querySelectorAll('.reedah-highlight')];
      results.push({background,expected,mode,highlight:spans.map(s=>s.textContent).join(''),text:text.slice(0,end),
        visible:spans.length>0 && spans.every(s=>getComputedStyle(s).backgroundColor!=='rgba(0, 0, 0, 0)' && s.getClientRects().length>0),
        focus:p.querySelectorAll('.reedah-highlight-word-focus').length>0});
      api.clearHighlight();
      results.at(-1).restored=p.innerHTML===original;
      section.remove();
    }
    return results;
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  for(const check of result.result.value) {
    assert.equal(check.mode,check.expected,`Background ${check.background}`);
    assert.equal(check.highlight,check.text,`Sentence selection on ${check.background}`);
    assert.equal(check.visible,true,`Visible background on ${check.background}`);
    assert.equal(check.focus,true,`Word focus on ${check.background}`);
    assert.equal(check.restored,true,`Restored inline markup on ${check.background}`);
  }
  console.log('PASS: visible sentence and word highlighting on ten modern/light/dark CSS backgrounds; inline markup restored.');
}
