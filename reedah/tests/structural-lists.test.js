const test = require('node:test');
const assert = require('node:assert/strict');
const {isStructuralListItem} = require('../prose_paragraphs');

function item(blocks) {
  const li = {tagName:'LI', childNodes:[], querySelectorAll:()=>blocks};
  for (const block of blocks) {
    block.textContent ??= 'A readable legal disclosure paragraph.';
    block.parentElement = {closest:()=>block.nested ? {} : li};
    block.closest = ()=>null;
    block.matches ??= ()=>false;
    block.ownerDocument = {defaultView:{getComputedStyle:()=>({
      display:block.display ?? 'block', visibility:'visible', opacity:'1'
    })}};
    block.parentElement.ownerDocument = block.ownerDocument;
  }
  return li;
}
test('Amazon accordion list yields its paragraphs instead of owning the whole notice', () => {
  assert.equal(isStructuralListItem(item([{}, {}])), true);
});
test('plain list items and inline spans remain a single narration target', () => {
  assert.equal(isStructuralListItem(item([])), false);
  assert.equal(isStructuralListItem(item([{display:'inline'}])), false);
});
test('nested list and quotation descendants do not change parent ownership', () => {
  assert.equal(isStructuralListItem(item([{nested:true}])), false);
});
test('table cells, block spans and generic div prose make structural list items', () => {
  for (const display of ['table', 'table-cell', 'block', 'grid']) {
    assert.equal(isStructuralListItem(item([{display}])), true);
  }
});

test('prose after a nested list must keep its position after the child items', () => {
  const li=item([]);
  li.childNodes=[
    {nodeType:3,textContent:'Introduction.'},
    {nodeType:1,matches:()=>true,textContent:'Nested item.'},
    {nodeType:3,textContent:'Conclusion.'}
  ];
  assert.equal(isStructuralListItem(li),true);
});

test('semantic paragraphs keep boundaries even with display contents or inline', () => {
  for (const display of ['contents','inline'])
    assert.equal(isStructuralListItem(item([{display,matches:()=>true}])),true);
});
