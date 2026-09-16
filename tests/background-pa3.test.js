const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
function event() {
  const handlers = [];
  return { addListener(fn) { handlers.push(fn); }, emit(...args) { return Promise.all(handlers.map(fn => fn(...args))); } };
}
function port(name) {
  return { name, onMessage: event(), onDisconnect: event(), sent: [], disconnected: false,
    postMessage(message) { this.sent.push(message); }, disconnect() { this.disconnected = true; } };
}
function setup(deferred = false) {
  const hosts = [], storage = [];
  const chrome = { action: {}, tabs: { onActivated: event(), onUpdated: event(), onRemoved: event() },
    commands: { onCommand: event() }, runtime: { onMessage: event(), onConnect: event(),
      connectNative(name) { assert.equal(name, 'com.reedah.sayer'); const host = port(name); hosts.push(host); return host; } },
    storage: { local: { get(keys, callback) { if (deferred) storage.push(callback); else callback({pa3Rate: 1.5, pa3CustomVocab: [{spelling:'PA3', pronunciation:'P A three'}]}); } } } };
  const context = vm.createContext({ chrome, console: {error() {}, info() {}}, setTimeout, clearTimeout });
  context.importScripts = (...files) => files.forEach(file => vm.runInContext(fs.readFileSync(path.join(__dirname, '..', file), 'utf8'), context));
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../background.js'), 'utf8'), context);
  const content = port('reedah-native');
  chrome.runtime.onConnect.emit(content);
  return {hosts, content, storage};
}
const start = {type:'start', utteranceId:'test', text:'PA3 is ready.', sentenceRanges:[{start:0,end:13}]};
test('background sends prepared text to PA3 bridge and returns audio with playback speed', async () => {
  const {hosts, content} = setup();
  await content.onMessage.emit(start);
  assert.equal(hosts.length, 1);
  assert.equal(hosts[0].sent[0].sentenceJobs[0].text, 'P A three is ready.');
  assert.equal(hosts[0].sent[0].action, 'speak');
  assert.equal(hosts[0].sent[0].speed, undefined);
  await hosts[0].onMessage.emit({event:'audio_chunk', utteranceId:'test', index:0, location:0, length:13, pieceIndex:0, pieceCount:2, progressStart:0, progressEnd:0.4, part:0, final:true, audioBase64:'UklGRg=='});
  const audio = content.sent.find(message => message.type === 'audio');
  assert.equal(audio.rate, 1.5);
  assert.equal(audio.location, 0);
  assert.equal(audio.length, 13);
  assert.equal(audio.pieceCount, 2);
  assert.equal(audio.progressEnd, 0.4);
  await content.onMessage.emit({type:'stop'});
  assert.equal(hosts[0].sent.at(-1).action, 'stop');
  assert.equal(hosts[0].disconnected, false);
  await hosts[0].onMessage.emit({event:'cancelled', utteranceId:'test'});
  assert.equal(hosts[0].disconnected, true);
});
test('stop during settings read prevents a late narration from starting', async () => {
  const {hosts, content, storage} = setup(true);
  const pending = content.onMessage.emit(start);
  await content.onMessage.emit({type:'stop'});
  storage[0]({});
  await pending;
  assert.equal(hosts.length, 0);
});
test('disconnect during settings read prevents native connection', async () => {
  const {hosts, content, storage} = setup(true);
  const pending = content.onMessage.emit(start);
  await content.onDisconnect.emit();
  storage[0]({});
  await pending;
  assert.equal(hosts.length, 0);
});
test('native failure reaches content without selecting another engine', async () => {
  const {hosts, content} = setup();
  await content.onMessage.emit(start);
  await hosts[0].onDisconnect.emit();
  assert.equal(content.sent.at(-1).error, 'bridge_unavailable');
  assert.equal(hosts.length, 1);
});

test('background forwards PCM format and explicit sentence completion', async () => {
  const {hosts, content}=setup(); await content.onMessage.emit(start);
  await hosts[0].onMessage.emit({event:'audio_chunk',utteranceId:'test',index:0,pieceIndex:0,stream:true,samples:1,sampleRate:24000,part:0,final:true,audioBase64:'AAAAAA=='});
  const audio=content.sent.at(-1);
  assert.equal(audio.stream,true); assert.equal(audio.samples,1); assert.equal(audio.sampleRate,24000);
  await hosts[0].onMessage.emit({event:'audio_end',utteranceId:'test',index:0,chunks:1});
  assert.equal(content.sent.at(-1).type,'audio_end');
  assert.equal(content.sent.at(-1).chunks,1);
  await hosts[0].onMessage.emit({event:'finished',utteranceId:'test'});
});

test('prefetch window promotion and consumption acknowledgements reach only their own bridge',async()=>{
  const {hosts,content}=setup();await content.onMessage.emit({...start,window:1});
  assert.equal(hosts[0].sent[0].window,1);
  await content.onMessage.emit({type:'window',window:2});
  assert.equal(hosts[0].sent.at(-1).action,'window');
  await content.onMessage.emit({type:'consumed',index:0});
  await content.onMessage.emit({type:'consumed',index:0});
  assert.equal(hosts[0].sent.filter(m=>m.action==='consumed').length,1);
  await hosts[0].onMessage.emit({event:'finished'});
});
test('two tabs have independent queues and stopping one leaves the other connected',async()=>{
  const one=setup(),two=setup();await one.content.onMessage.emit(start);await two.content.onMessage.emit(start);
  await one.content.onMessage.emit({type:'stop'});
  assert.equal(two.hosts[0].sent.length,1);assert.equal(two.hosts[0].disconnected,false);
  await one.hosts[0].onMessage.emit({event:'cancelled'});
  await two.hosts[0].onMessage.emit({event:'finished'});
});
