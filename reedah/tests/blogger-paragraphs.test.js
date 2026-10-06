const assert = require('node:assert/strict');
const test = require('node:test');
const {inlineRuns} = require('../blogger_paragraphs');

test('Blogger runs keep inline links with prose and split on line breaks and blocks', () => {
  const nodes = ['text', 'link', 'text', 'br', 'br', 'text', 'table', 'text', 'div', 'text'];
  assert.deepEqual(inlineRuns(nodes, node => ['br', 'table', 'div'].includes(node)),
    [['text', 'link', 'text'], ['text'], ['text'], ['text']]);
});

test('empty and boundary-only Blogger content produces no runs', () => {
  assert.deepEqual(inlineRuns([], () => false), []);
  assert.deepEqual(inlineRuns(['br', 'br'], () => true), []);
});

test('Blogger runs retain original node identities and their order', () => {
  const nodes = [{text: 'Read '}, {link: 'this'}, {text: ' now.'}];
  const runs = inlineRuns(nodes, () => false);
  assert.equal(runs.length, 1);
  runs[0].forEach((node, index) => assert.equal(node, nodes[index]));
});
