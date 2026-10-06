const assert = require('node:assert/strict');
const test = require('node:test');
const {hasReadableText, isLinkedProse, inlineRuns} = require('../prose_paragraphs');

test('short semantic paragraphs and multilingual sentences remain readable', () => {
  for (const text of ['No.', 'כן.', '你好。', 'はい', '好的', '한국어']) assert.equal(hasReadableText(text), true, text);
  for (const text of ['I', '是', 'כן', '7']) assert.equal(hasReadableText(text, true), true, text);
  for (const text of ['', '   ', '===', '…', '🙂']) assert.equal(hasReadableText(text, true), false, text);
  assert.equal(hasReadableText('OK'), false, 'unmarked short UI label');
});

test('linked prose must be substantial and sentence-like', () => {
  assert.equal(isLinkedProse('An entire meaningful sentence can be a hyperlink in an article.'), true);
  assert.equal(isLinkedProse('A quotation can also end a linked sentence like “this.”'), true);
  for (const text of ['Next page', 'Navigation link', 'Read more.', 'A long navigation label without any sentence punctuation']) {
    assert.equal(isLinkedProse(text), false, text);
  }
});

test('mixed content retains separate bare runs around semantic paragraphs', () => {
  assert.deepEqual(inlineRuns(['intro', 'p', 'conclusion'], value=>value==='p'), [['intro'], ['conclusion']]);
});

test('visibility and disclosure changes trigger rescans without reacting to narration classes', () => {
  const {isRelevantMutation} = require('../prose_paragraphs');
  const change = (attributeName, oldValue, current, owned = false) => ({type:'attributes', attributeName, oldValue,
    target:{closest:()=>owned, getAttribute:()=>current}});
  assert.equal(isRelevantMutation(change('class', 'gone', '')), true);
  assert.equal(isRelevantMutation(change('class', 'article', 'article reedah-prose-paragraph')), false);
  assert.equal(isRelevantMutation(change('class', 'one two', 'two one')), false);
  for (const attribute of ['open', 'style', 'hidden', 'role', 'inert']) {
    assert.equal(isRelevantMutation(change(attribute, '', 'changed')), true, attribute);
  }
  assert.equal(isRelevantMutation(change('style', '', 'changed', true)), false);
  assert.equal(isRelevantMutation({type:'childList'}), true);
  assert.equal(isRelevantMutation({type:'characterData'}), true);
});

test('blank lines divide a semantic post while single breaks stay within paragraphs', () => {
  const {blankLineRuns} = require('../prose_paragraphs');
  const split = nodes => blankLineRuns(nodes, node=>node==='br', node=>node===' ');
  assert.deepEqual(split(['first','br','br','second','br','br','br','third']), [['first'],['second'],['third']]);
  assert.deepEqual(split(['first','br','line','br',' ','br','second']), [['first','br','line'],['second']]);
  assert.deepEqual(split(['br','br','first','br','br']), [['first']]);
  assert.deepEqual(split(['first','link','last']), [['first','link','last']]);
  assert.deepEqual(split([]), []);
});
