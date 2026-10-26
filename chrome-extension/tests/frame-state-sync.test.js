const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function setup({error, throws = false, response = {enabled:true}, enabled = false, top = false} = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../content.js'), 'utf8');
  const start = source.indexOf('  function notifyState()');
  const end = source.indexOf('  function attachObservers()', start);
  const sent=[], errors=[], info=[], actions=[];
  const state={enabled};
  const window={};
  window.top=top?window:{};
  const chrome={runtime:{sendMessage(message,callback) {
    sent.push(message);
    if (throws) throw error;
    if (!callback) return;
    if (error) chrome.runtime.lastError=error;
    try { callback(response); }
    finally { delete chrome.runtime.lastError; }
  }}};
  const context=vm.createContext({window,chrome,state,
    console:{error(...args){errors.push(args);},info(...args){info.push(args);}},
    enable(){actions.push('enable');state.enabled=true;},
    disable(){actions.push('disable');state.enabled=false;}
  });
  vm.runInContext(source.slice(start,end)+'\nnotifyState();',context);
  return {sent,errors,info,actions,state};
}

for (const message of [
  'Could not establish connection. Receiving end does not exist.',
  'The message port closed before a response was received.',
  'A listener indicated an asynchronous response by returning true, but the message channel closed before a response was received',
  'Extension context invalidated.'
]) {
  test(`state probe stops without retries or state changes: ${message}`,()=>{
    const {sent,errors,info,actions}=setup({error:{message}});
    assert.equal(sent.length,1);
    assert.equal(errors.length,0);
    assert.equal(info.length,1);
    assert.equal(info[0][1],message);
    assert.deepEqual(actions,[]);
  });
}

test('invalidated extension context thrown during send is informational',()=>{
  const {errors,info,actions}=setup({error:new Error('Extension context invalidated.'),throws:true});
  assert.equal(errors.length,0);
  assert.equal(info.length,1);
  assert.deepEqual(actions,[]);
});

test('unexpected callback and synchronous failures expose the actual message',()=>{
  for (const throws of [false,true]) {
    const {errors,info,actions}=setup({error:{message:'Unexpected messaging failure'},throws});
    assert.equal(errors.length,1);
    assert.equal(errors[0][1],'Unexpected messaging failure');
    assert.equal(info.length,0);
    assert.deepEqual(actions,[]);
  }
});

test('successful synchronization follows enabled state and avoids redundant transitions',()=>{
  assert.deepEqual(setup().actions,['enable']);
  assert.deepEqual(setup({enabled:true,response:{enabled:false}}).actions,['disable']);
  assert.deepEqual(setup({enabled:true}).actions,[]);
  assert.deepEqual(setup({response:{enabled:false}}).actions,[]);
});

test('top document still publishes its own enabled state',()=>{
  const {sent,actions}=setup({top:true,enabled:true});
  assert.equal(sent[0].type,'reedah-state');
  assert.equal(sent[0].enabled,true);
  assert.deepEqual(actions,[]);
});
