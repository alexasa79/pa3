const test = require('node:test');
const assert = require('node:assert/strict');
const {isStructuralQuote} = require('../prose_paragraphs');
const semantic='p, blockquote, li, .reedah-prose-paragraph';
const math='.formula';

function quote(children) {
  return {tagName:'BLOCKQUOTE', querySelectorAll:()=>children.map(child=>({
    closest(selector) {return child.formula && selector===math ? {} : null;},
    matches() {return !!child.semantic;},
    ownerDocument:{defaultView:{getComputedStyle:()=>({
      display:child.display ?? 'inline', visibility:child.hidden?'hidden':'visible', opacity:'1'
    })}}
  }))};
}
test('separate quoted paragraphs remain separate even when CSS makes them inline',()=>{
  assert.equal(isStructuralQuote(quote([{semantic:true},{semantic:true}]),semantic,math),true);
});
test('bare quotation with inline emphasis and atomic math stays one paragraph',()=>{
  assert.equal(isStructuralQuote(quote([{},{formula:true,display:'block'}]),semantic,math),false);
});
test('quoted divs, table cells and block spans are structural boundaries',()=>{
  for(const display of ['block','table','table-cell','flex','grid'])
    assert.equal(isStructuralQuote(quote([{display}]),semantic,math),true);
});
test('hidden descendants do not create quotation boundaries',()=>{
  assert.equal(isStructuralQuote(quote([{hidden:true,semantic:true}]),semantic,math),false);
});
