const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function setup(tabs = [{id:7}], messagingError = null) {
  const sent=[], errors=[], info=[];
  const event=()=>({addListener(fn){this.handler=fn;}});
  const chrome={
    action:{setIcon(){assert.fail('Playback state must not replace the PA3 icon');}},tabs:{onActivated:event(),onUpdated:event(),onRemoved:event(),
      query(options, callback){assert.deepEqual(JSON.parse(JSON.stringify(options)), {active:true,currentWindow:true});callback(tabs);},
      sendMessage(...args){
        sent.push(args);
        chrome.runtime.lastError = messagingError;
        try { args.at(-1)?.(messagingError ? undefined : {enabled:true}); }
        finally { delete chrome.runtime.lastError; }
      }},
    commands:{onCommand:event()},runtime:{onMessage:event(),onConnect:event()}
  };
  const context=vm.createContext({chrome,console:{error(...args){errors.push(args);},info(...args){info.push(args);}},setTimeout,clearTimeout,
    OffscreenCanvas:class {constructor(){assert.fail('The extension icon must use the packaged PA3 artwork');}},
    ImageData:class {}});
  context.importScripts=(...files)=>files.forEach(file=>vm.runInContext(fs.readFileSync(path.join(__dirname,'..',file),'utf8'),context));
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../background.js'),'utf8'),context);
  return {sent,errors,info,receive:chrome.runtime.onMessage.handler,command:chrome.commands.onCommand.handler};
}

test('keyboard commands reach the active tab and playback commands reach every frame',()=>{
  const {sent,command}=setup();
  for (const [name,type] of Object.entries({
    'toggle-overlay':'reedah-toggle', 'pause-playback':'reedah-pause',
    'previous-sentence':'reedah-previous-sentence', 'next-sentence':'reedah-next-sentence'
  })) {
    command(name);
    const args=sent.at(-1);
    assert.equal(args[0],7);
    assert.equal(args[1].type,type);
    if (name==='toggle-overlay') assert.equal(args[2].frameId,0);
    else assert.equal(args.length,3);
  }
  command('activate');
  command('_execute_action');
  assert.equal(sent.length,4);
});

test('keyboard commands without an active tab do nothing',()=>{
  const {sent,command}=setup([]);
  command('next-sentence');
  assert.equal(sent.length,0);
});

test('keyboard commands without a page receiver are informational',()=>{
  const {command,errors,info}=setup([{id:7}], {
    message:'Could not establish connection. Receiving end does not exist.'
  });
  command('toggle-overlay');
  assert.equal(errors.length,0);
  assert.equal(info.length,1);
});

test('unexpected keyboard delivery errors remain visible with their message',()=>{
  const {command,errors,info}=setup([{id:7}], {message:'Unexpected messaging failure'});
  command('pause-playback');
  assert.equal(errors.length,1);
  assert.equal(errors[0][1],'Unexpected messaging failure');
  assert.equal(info.length,0);
});

test('manifest assigns four distinct shortcuts without an activation binding',()=>{
  const {commands}=require('../manifest.json');
  assert.deepEqual(Object.keys(commands).sort(),['next-sentence','pause-playback','previous-sentence','toggle-overlay']);
  for (const platform of ['default','mac']) {
    assert.equal(new Set(Object.values(commands).map(command=>command.suggested_key[platform])).size,4);
    for (const [name,key] of Object.entries({
      'previous-sentence':'Alt+A', 'next-sentence':'Alt+D',
      'pause-playback':'Alt+S', 'toggle-overlay':'Alt+X'
    })) assert.equal(commands[name].suggested_key[platform],key);
  }
});
test('top document state broadcasts to frames; child state cannot overwrite it',()=>{
  const {sent,receive}=setup();
  receive({type:'reedah-state',enabled:true},{tab:{id:7},frameId:0});
  assert.equal(sent.at(-1)[1].type,'reedah-set-enabled');
  let response;
  receive({type:'reedah-state',enabled:false},{tab:{id:7},frameId:4});
  receive({type:'reedah-frame-ready'},{tab:{id:7},frameId:5},value=>response=value);
  assert.equal(response.enabled,true);
});
test('late frames recover enabled state after background worker restart',()=>{
  const {sent,receive}=setup();let response;
  assert.equal(receive({type:'reedah-frame-ready'},{tab:{id:7},frameId:8},value=>response=value),true);
  assert.equal(sent[0][2].frameId,0);
  assert.equal(response.enabled,true);
});
test('starting a frame broadcasts a stop to other frame tokens',()=>{
  const {sent,receive}=setup();
  receive({type:'reedah-frame-play',token:'frame-a'},{tab:{id:7},frameId:4});
  assert.equal(sent[0][1].type,'reedah-stop-other-frame');
  assert.equal(sent[0][1].token,'frame-a');
});
test('one declarative script reaches ordinary and inherited-origin frames without double injection',()=>{
  const {content_scripts:scripts}=require('../manifest.json');
  assert.equal(scripts.length,1);
  assert.equal(scripts[0].all_frames,true);
  assert.equal(scripts[0].match_origin_as_fallback,true);
  assert.deepEqual(scripts[0].matches,['<all_urls>']);
});

test('frame control state is delivered only to the top document',()=>{
  const {sent,receive}=setup();
  receive({type:'reedah-controls-state',token:'child',snapshot:{active:true}},
    {tab:{id:7},frameId:3});
  assert.equal(sent.length,1);
  assert.equal(sent[0][2].frameId,0);
  assert.equal(sent[0][1].token,'child');
  receive({type:'reedah-controls-state'},{tab:{id:7},frameId:0});
  assert.equal(sent.length,1);
});
test('only the page toolbar may route playback actions to the owning frame',()=>{
  const {sent,receive}=setup();
  receive({type:'reedah-controls-action',token:'child',action:'playpause'},
    {tab:{id:7},frameId:3});
  assert.equal(sent.length,0);
  receive({type:'reedah-controls-action',token:'child',action:'playpause'},
    {tab:{id:7},frameId:0});
  assert.equal(sent.length,1);
  assert.equal(sent[0][1].token,'child');
  assert.equal(sent[0][1].action,'playpause');
});


test('a child arriving before the top script stops synchronization without reporting an extension error',()=>{
  const {receive,sent,errors,info}=setup([{id:7}], {
    message:'Could not establish connection. Receiving end does not exist.'
  });
  let response;
  receive({type:'reedah-frame-ready'},{tab:{id:7},frameId:8},value=>response=value);
  assert.equal(response.enabled,false);
  assert.equal(errors.length,0);
  assert.equal(info.length,1);
  // The missing receiver must not cache a disabled state. A second frame
  // still probes the top document, and its eventual startup broadcasts state.
  receive({type:'reedah-frame-ready'},{tab:{id:7},frameId:9},()=>{});
  assert.equal(sent.length,2);
  receive({type:'reedah-state',enabled:true},{tab:{id:7},frameId:0});
  assert.equal(sent.at(-1)[1].type,'reedah-set-enabled');
  assert.equal(sent.at(-1)[1].enabled,true);
});

test('unexpected frame synchronization errors remain visible',()=>{
  const {receive,errors,info}=setup([{id:7}],{message:'Unexpected messaging failure'});
  let response;
  receive({type:'reedah-frame-ready'},{tab:{id:7},frameId:8},value=>response=value);
  assert.equal(response.enabled,false);
  assert.equal(errors.length,1);
  assert.equal(errors[0][0],'PA3 extension: Unable to synchronize a new frame.');
  assert.equal(errors[0][1],'Unexpected messaging failure');
  assert.equal(info.length,0);
});
