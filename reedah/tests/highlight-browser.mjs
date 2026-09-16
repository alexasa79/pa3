import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
export async function checkHighlights(call) {
  const css=await readFile(new URL('../content.css',import.meta.url),'utf8');
  const result=await call('Runtime.evaluate',{expression:`(() => {
    const style=document.createElement('style');style.textContent=${JSON.stringify(css)}+' .reedah-highlight-word { transition: none; }';document.head.appendChild(style);
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
      section.style.width='290px';
      section.innerHTML='<p>First sentence with <strong>bold text</strong> <em>beside</em> <code>code</code>, plus nonbreaking&nbsp;spaces and a longer ending that wraps onto another line. Next sentence.</p>';
      document.body.appendChild(section);
      const p=section.firstElementChild,original=p.innerHTML;
      const text=api.getFullText(p),end=text.indexOf('. ')+1;
      const mode=ReedahHighlightTheme.detectHighlightMode(p),height=p.getBoundingClientRect().height;
      api.highlightSentence(p,{start:0,end});
      const spans=[...p.querySelectorAll('.reedah-highlight')];
      const focusSpans=[...p.querySelectorAll('.reedah-highlight-word')];
      const positions=[0,0.5,1].map(progress=>{
        api.applyHighlightWordFocus(progress);
        const active=focusSpans.filter(s=>s.style.getPropertyValue('--reedah-word-focus')==='1');
        const background=active.map(s=>getComputedStyle(s).backgroundColor);
        return {
          text:active.map(s=>s.textContent).join(''),
          continuous:background.length>1 && new Set(background).size===1 && background[0]!=='rgba(0, 0, 0, 0)',
          noUnderline:focusSpans.every(s=>['none','normal'].includes(getComputedStyle(s,'::after').content))
        };
      });
      results.push({background,expected,mode,highlight:spans.map(s=>s.textContent).join(''),text:text.slice(0,end),
        visible:spans.length>0 && spans.every(s=>getComputedStyle(s).backgroundColor!=='rgba(0, 0, 0, 0)' && s.getClientRects().length>0),
        focus:p.querySelectorAll('.reedah-highlight-word-focus').length>0,
        tintedText:focusSpans.map(s=>s.textContent).join(''),
        whitespaceNode:focusSpans.some(s=>/^\\s+$/.test(s.textContent)),
        stableLayout:p.getBoundingClientRect().height===height,
        positions});
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
    assert.equal(check.tintedText,check.text,`Tint covers letters and whitespace on ${check.background}`);
    assert.equal(check.whitespaceNode,true,`Whitespace between inline elements gets tinted on ${check.background}`);
    assert.equal(check.stableLayout,true,`Wrapping unchanged on ${check.background}`);
    for(const position of check.positions) {
      assert.equal(position.continuous,true,`Uniform tint across the active phrase on ${check.background}`);
      assert.equal(position.noUnderline,true,`No decorative underline on ${check.background}`);
    }
    assert.ok(check.positions[0].text.startsWith('First sentence'),`Focus begins at sentence start on ${check.background}`);
    assert.ok(check.positions[2].text.endsWith('another line.'),`Focus reaches sentence end on ${check.background}`);
    assert.notEqual(check.positions[0].text,check.positions[1].text,`Focus follows playback on ${check.background}`);
    assert.equal(check.restored,true,`Restored inline markup on ${check.background}`);
  }
  console.log('PASS: continuous phrase tint including spaces, playback progress, unchanged wrapping and inline cleanup on ten light/dark CSS backgrounds.');
}
