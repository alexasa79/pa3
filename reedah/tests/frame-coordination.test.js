const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function setup() {
  const sent=[];
  const event=()=>({addListener(fn){this.handler=fn;}});
  const chrome={
    action:{},tabs:{onActivated:event(),onUpdated:event(),onRemoved:event(),
      sendMessage(...args){sent.push(args);args.at(-1)?.({enabled:true});}},
    commands:{onCommand:event()},runtime:{onMessage:event(),onConnect:event()}
  };
  const context=vm.createContext({chrome,console,setTimeout,clearTimeout});
  context.importScripts=(...files)=>files.forEach(file=>vm.runInContext(fs.readFileSync(path.join(__dirname,'..',file),'utf8'),context));
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../background.js'),'utf8'),context);
  return {sent,receive:chrome.runtime.onMessage.handler};
}
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
