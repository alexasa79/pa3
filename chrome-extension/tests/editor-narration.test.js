const assert = require('node:assert/strict');
const test = require('node:test');
const {isConfluenceLocation, textRuns, focusWords, supportsHighlights} = require('../editor_narration');

test('editor support is scoped to Confluence Cloud document URLs', () => {
  for (const pathname of ['/wiki/spaces/RED/pages/2970124292/Example', '/wiki/spaces/TEST/pages/123']) {
    assert.equal(isConfluenceLocation({hostname:'ime-ddn.atlassian.net',pathname}),true);
  }
  for (const hostname of ['atlassian.net.evil.test','fakeatlassian.net','example.com','atlassian.net']) {
    assert.equal(isConfluenceLocation({hostname,pathname:'/wiki/spaces/TEST/pages/123'}),false);
  }
  for (const pathname of ['/jira/issues','/wiki/home','/wiki/spaces/TEST/blog/123']) {
    assert.equal(isConfluenceLocation({hostname:'ime-ddn.atlassian.net',pathname}),false);
  }
  assert.equal(isConfluenceLocation(null),false);
});

test('cursor markers are omitted without shifting offsets into original text nodes', () => {
  const source='\u200d🙂 Read\u200b this\ntext.\ufeff';
  const runs=textRuns(source);
  assert.equal(runs.map(run=>run.text).join(''),'🙂 Read this text.');
  for (const run of runs) assert.equal(source.slice(run.nodeStart,run.nodeStart+run.text.length).replace(/[\r\n]/g,' '),run.text);
  assert.deepEqual(textRuns('\u200d'),[]);
  assert.deepEqual(textRuns(''),[]);
});

test('real emoji and language joiners survive narration', () => {
  for (const text of ['👩‍💻 explains the design.', '👨‍👩‍👧‍👦', 'क्‍ष']) {
    assert.deepEqual(textRuns(text),[{text,nodeStart:0}]);
  }
});

test('phrase focus covers spaces and uses UTF-16 offsets', () => {
  const text='  🙂 Read\u00a0this example. ';
  const words=focusWords(text);
  assert.deepEqual(words,[{start:0,end:5},{start:5,end:10},{start:10,end:15},{start:15,end:24}]);
  assert.equal(words.map(word=>text.slice(word.start,word.end)).join(''),text);
  assert.deepEqual(focusWords('   '),[]);
});

test('an unsupported browser cannot select the DOM-mutating highlighter for an editor', () => {
  assert.equal(supportsHighlights({}),false);
  assert.equal(supportsHighlights({Highlight(){},CSS:{}}),false);
  assert.equal(supportsHighlights({Highlight(){},CSS:{highlights:new Map()}}),true);
});
