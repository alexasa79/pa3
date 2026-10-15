import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

// Informational audit, NOT a passing regression oracle. Differences from the
// proposed paragraph-boundary rule are printed for review, never blessed here.
export async function auditParagraphExceptions(call) {
  const rows=[
    ['figure caption','<figure><figcaption><p>Alpha paragraph.</p><p>Beta paragraph.</p></figcaption></figure>',2],
    ['definition body','<dl><dd><p>Alpha paragraph.</p><p>Beta paragraph.</p></dd></dl>',2],
    ['quotation inside caption','<figure><figcaption><blockquote><p>Alpha paragraph.</p><p>Beta paragraph.</p></blockquote></figcaption></figure>',2],
    ['block spans inside semantic paragraph','<p><span style="display:block">Alpha paragraph.</span><span style="display:block">Beta paragraph.</span></p>',2],
    ['generic blocks inside custom paragraph','<div role="paragraph"><div>Alpha paragraph.</div><div>Beta paragraph.</div></div>',2],
    ['block spans inside heading','<h2><span style="display:block">Alpha heading.</span><span style="display:block">Beta heading.</span></h2>',2],
    ['bare blank lines in generic div','<div style="white-space:pre-wrap">Alpha paragraph.\n\nBeta paragraph.</div>',2],
    ['nested blank lines amid inline prose','<p>Introduction. <span>Alpha paragraph.<br><br>Beta paragraph.</span> Conclusion.</p>',2],
    ['bare text around paragraphs in contenteditable','<div contenteditable="true">Alpha paragraph.<p>Beta paragraph.</p></div>',2],
    ['form contains prose','<form><p>Alpha paragraph.</p></form>',1],
    ['aside contains prose','<aside><p>Alpha paragraph.</p></aside>',1],
    ['short hyperlink paragraph','<p><a href="#">Read more</a></p>',1],
    ['unpunctuated long hyperlink paragraph','<p><a href="#">This entire long paragraph is linked but does not end in punctuation</a></p>',1],
    ['short generic bare text','<div>Yes</div>',1],
    ['semantic short paragraph','<p>Yes</p>',1],
    ['heading with two letters','<h2>AI</h2>',1],
    ['visible summary of open disclosure','<details open><summary>Alpha summary.</summary><p>Beta paragraph.</p></details>',2],
    ['header in main but not article','<header><h2>Alpha heading.</h2><p>Beta paragraph.</p></header>',2],
    ['simple nested list','<ul><li>Alpha paragraph.<ul><li>Beta paragraph.</li></ul></li></ul>',2],
    ['quotation with nested navigation','<blockquote>Alpha paragraph.<nav><p>Navigation text.</p></nav></blockquote>',1],
    ['quotation with nested preformatted code','<blockquote>Alpha paragraph.<pre>Code block.</pre></blockquote>',1],
    ['quotation with hidden duplicate','<blockquote>Alpha paragraph.<span hidden>Hidden duplicate.</span></blockquote>',1],
    ['inline formula','<p>Alpha <math><mi>x</mi></math> paragraph.</p>',1]
  ];
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  const content=scripts.pop().replace(/\}\)\(\);\s*$/, 'globalThis.auditAPI={enable,disable,getCandidates,getFullText};})();');
  await call('Page.navigate',{url:'about:blank'});
  const loaded=await call('Runtime.evaluate',{expression:'globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){}}};'+scripts.join('\n')+'\n'+content});
  assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
  const result=await call('Runtime.evaluate',{expression:`(() => {
    const rows=${JSON.stringify(rows)};
    document.body.innerHTML='<main>'+rows.map((row,i)=>'<section data-audit="'+i+'">'+row[1]+'</section>').join('')+'</main>';
    auditAPI.enable();const candidates=auditAPI.getCandidates();
    const output=rows.map(([name,,proposedCount],i)=>{
      const root=document.querySelector('[data-audit="'+i+'"]');
      const texts=candidates.filter(el=>root.contains(el)).map(el=>auditAPI.getFullText(el).replace(/\\s+/g,' ').trim());
      return {name,proposedCount,actualCount:texts.length,texts};
    });
    auditAPI.disable();return output;
  })()`,returnByValue:true});
  assert.ok(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));
  console.log('PARAGRAPH EXCEPTION AUDIT (informational; differences require review):');
  for(const row of result.result.value)console.log(JSON.stringify(row));
}
