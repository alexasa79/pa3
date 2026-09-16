// Uses Node's built-in WebSocket and a separate Chrome profile. No user tabs are accessed.
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const profile=await mkdtemp(join(tmpdir(),'reedah-audio-browser-'));
const log=await open(join(profile,'diagnostics.log'),'w');
const browser=spawn(process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',[
  '--headless','--no-first-run','--no-default-browser-check','--disable-extensions',
  '--disable-background-networking','--disable-sync','--autoplay-policy=no-user-gesture-required',
  '--remote-debugging-port=0','--remote-debugging-address=127.0.0.1',`--user-data-dir=${profile}`,'about:blank'
],{detached:true,stdio:['ignore','ignore',log.fd]});
let socket,launchError;browser.on('error',error=>launchError=error);
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
try {
  let port;
  for(let i=0;i<100;i++) {
    if(launchError)throw launchError;
    try {port=(await readFile(join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0];break;}
    catch(error) {if(error.code!=='ENOENT')throw error;await delay(100);}
  }
  if(!port)throw Error('Chrome did not start');
  const pages=await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket=new WebSocket(pages.find(page=>page.type==='page').webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
  let next=0;const pending=new Map();
  socket.onmessage=event=>{
    const message=JSON.parse(event.data), request=pending.get(message.id);
    if(request){pending.delete(message.id);clearTimeout(request.timer);message.error?request.reject(Error(JSON.stringify(message.error))):request.resolve(message.result);}
  };
  function call(method,params={}) {
    return new Promise((resolve,reject)=>{
      const id=++next,timer=setTimeout(()=>{pending.delete(id);reject(Error('Chrome command timed out: '+method));},10000);
      pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({id,method,params}));
    });
  }
  await call('Page.enable');
  await call('Page.navigate',{url:new URL('./stream-audio-browser.html',import.meta.url).href});
  let result='PENDING';
  for(let i=0;i<200;i++) {
    const response=await call('Runtime.evaluate',{expression:'document.querySelector("#result")?.textContent',returnByValue:true});
    result=response.result.value ?? 'PENDING';
    if(result!=='PENDING')break;
    await delay(100);
  }
  if(!result.startsWith('PASS:'))throw Error(result);
  console.log(result);
} finally {
  socket?.close();
  if(browser.pid){try{process.kill(-browser.pid,'SIGTERM');}catch(error){if(error.code!=='ESRCH')throw error;}}
  await delay(200);
  if(browser.pid){try{process.kill(-browser.pid,'SIGKILL');}catch(error){if(error.code!=='ESRCH')throw error;}}
  await log.close();await rm(profile,{recursive:true,force:true});
}
