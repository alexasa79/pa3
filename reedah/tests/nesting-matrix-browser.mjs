import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

// Exhaustive bounded grammar: all 4^1 + ... + 4^5 structural paths.
// Each path carries two independent paragraphs, never an implementation-derived oracle.
const wrappers = {
  list: text => '<ul><li>'+text+'</li></ul>',
  table: text => '<table><tbody><tr><td>'+text+'</td></tr></tbody></table>',
  generic: text => '<div>'+text+'</div>',
  custom: text => '<div role="paragraph">'+text+'</div>'
};
export function nestingCases() {
  const cases=[];
  function visit(path) {
    if(path.length) {
      const leaf = '<p>First independent paragraph.</p><p>Second independent paragraph.</p>';
      cases.push({name:path.join('/'),html:path.reduceRight((text,key)=>wrappers[key](text),leaf),
        expected:['First independent paragraph.','Second independent paragraph.']});
      let mixed=leaf, expected=['First independent paragraph.','Second independent paragraph.'];
      for(let i=path.length-1;i>=0;i--) {
        const before='Introduction at level '+i+'.', after='Conclusion at level '+i+'.';
        mixed=wrappers[path[i]](before+mixed+after);
        expected=[before,...expected,after];
      }
      cases.push({name:path.join('/')+'/mixed',html:mixed,expected});
    }
    if(path.length<5)for(const key of Object.keys(wrappers))visit([...path,key]);
  }
  visit([]);
  const extras = [
    ['amazon accordion','<ul><li><button>Expand notice</button><div aria-hidden="false"><div><p>First independent paragraph.</p><p>Second independent paragraph.</p></div></div></li></ul>'],
    ['mixed list','<ul><li>First independent paragraph.<table><tr><td>Second independent paragraph.</td></tr></table></li></ul>'],
    ['block spans','<ul><li><span style="display:block">First independent paragraph.</span><span style="display:block">Second independent paragraph.</span></li></ul>'],
    ['parser repaired paragraph table','<p>First independent paragraph.<table><tr><td><p>Second independent paragraph.</p></td></tr></table></p>'],
    ['parser repaired paragraph list','<p>First independent paragraph.<ul><li><p>Second independent paragraph.</p></li></ul></p>']
  ];
  for(const [name,html] of extras)cases.push({name,html,expected:['First independent paragraph.','Second independent paragraph.']});
  // Cross paragraph representations with containers, including aggregate semantic owners.
  const leaves = [
    '<p>First independent paragraph.</p>',
    '<div>First independent paragraph.</div>',
    '<span style="display:block">First independent paragraph.</span>',
    '<div role="paragraph">First independent paragraph.</div>',
    'First independent paragraph.',
    '<p style="display:contents">First independent paragraph.</p>',
    '<p style="display:inline">First independent paragraph.</p>',
    '<p><a href="#">First independent paragraph with a sufficiently long link.</a></p>'
  ];
  const containers={...wrappers,quote:t=>'<blockquote>'+t+'</blockquote>',
    caption:t=>'<figure><figcaption>'+t+'</figcaption></figure>',
    definition:t=>'<dl><dd>'+t+'</dd></dl>',contents:t=>'<div style="display:contents">'+t+'</div>',
    disclosure:t=>'<details open><summary>Open notice</summary>'+t+'</details>'};
  for(const [name,wrap] of Object.entries(containers))for(let i=0;i<leaves.length;i++)
    cases.push({name:name+'/leaf-'+i,html:wrap(leaves[i]),expected:[i===7?'First independent paragraph with a sufficiently long link.':'First independent paragraph.']});
  for(const [name,wrap] of Object.entries(containers))for(const excluded of ['hidden','inert','aria-hidden="true"','style="display:none"','style="opacity:0"'])
    cases.push({name:name+'/'+excluded,html:wrap('<div '+excluded+'><p>Excluded paragraph.</p></div>'),expected:[]});
  return cases;
}
export async function checkNestingMatrix(call) {
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  const scripts=await Promise.all(manifest.content_scripts[0].js.map(file=>readFile(new URL('../'+file,import.meta.url),'utf8')));
  await call('Page.navigate',{url:'about:blank'});
  const content=scripts.pop().replace(/\}\)\(\);\s*$/, 'globalThis.matrixAPI={enable,disable,scanParagraphs,getCandidates,getFullText,buildNarrationPayload,updateHoverFromPoint,updatePositions,state};})();');
  const setup='globalThis.chrome={runtime:{onMessage:{addListener(){}},sendMessage(){}}};';
  const loaded=await call('Runtime.evaluate',{expression:setup+scripts.join('\n')+'\n'+content});
  assert.ok(!loaded.exceptionDetails,JSON.stringify(loaded.exceptionDetails));
  const cases=nestingCases();
  for(let offset=0;offset<cases.length;offset+=20) {
    const batch=cases.slice(offset,offset+20);
    const response=await call('Runtime.evaluate',{expression:`(() => {
      const api=matrixAPI, rows=${JSON.stringify(batch)};
      document.body.innerHTML='<main>'+rows.map((r,i)=>'<section data-case="'+i+'">'+r.html+'</section>').join('')+'</main>';
      const original=document.body.innerHTML;
      api.enable();
      const read=()=>{const all=api.getCandidates();return rows.map((row,i)=>{
        const group=document.querySelector('[data-case="'+i+'"]');
        return all.filter(el=>group.contains(el)).map(el=>api.getFullText(el).replace(/\\s+/g,' ').trim());
      })};
      const first=read();api.scanParagraphs();const second=read();
      const controls=api.getCandidates().every(el=>api.state.overlays.has(el));
      api.disable();
      return {first,second,controls,restored:document.body.innerHTML===original};
    })()`,returnByValue:true});
    assert.ok(!response.exceptionDetails,JSON.stringify(response.exceptionDetails));
    const data=response.result.value;
    batch.forEach((row,i)=>assert.deepEqual(data.first[i],row.expected,row.name));
    assert.deepEqual(data.second,data.first,'stable rescan at '+offset);
    assert.ok(data.controls,'controls at '+offset);
    assert.ok(data.restored,'DOM restoration at '+offset);
  }
  // Reproduce the actual symptom: hover a paragraph far below the accordion heading.
  const hover=await call('Runtime.evaluate',{expression:`(() => {
    document.body.innerHTML='<main><ul><li><button>Notice</button><div style="height:1800px"></div><p id="target">A legal notice far below its heading.</p><p>Another paragraph.</p></li></ul></main>';
    matrixAPI.enable();const p=document.querySelector('#target');p.scrollIntoView();
    const r=p.getBoundingClientRect();matrixAPI.updateHoverFromPoint(r.left+30,r.top+5);matrixAPI.updatePositions();
    const overlay=matrixAPI.state.overlays.get(p);
    const result=matrixAPI.state.hoveredEl===p && overlay?.style.display!=='none';
    matrixAPI.disable();return result;
  })()`,returnByValue:true});
  assert.equal(hover.result.value,true,'Amazon paragraph hover owns a visible control');
  const ordered=await call('Runtime.evaluate',{expression:`(() => {
    document.body.innerHTML='<main><ol start="7"><li><p>Alpha paragraph.</p><p>Beta paragraph.</p></li></ol></main>';
    matrixAPI.enable();
    const payloads=matrixAPI.getCandidates().map(el=>matrixAPI.buildNarrationPayload(el));
    matrixAPI.disable();return payloads;
  })()`,returnByValue:true});
  assert.deepEqual(ordered.result.value,[
    {text:'Seven. Alpha paragraph.',highlightTextOffset:7},
    {text:'Beta paragraph.',highlightTextOffset:0}
  ],'ordered list prefix belongs only to the first paragraph');
  console.log('PASS: '+cases.length+' nesting matrix cases through five levels, exact text ownership, exclusions, rescan stability, controls, cleanup and Amazon hover.');
}
