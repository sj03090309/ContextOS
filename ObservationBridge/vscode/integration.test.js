'use strict';
// Actual extension module + real Unix sockets + production Swift core.
// VS Code API events and clock are deliberately synthetic. No editor or GUI runs.
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),net=require('node:net');
const {spawn}=require('node:child_process'),readline=require('node:readline');
const {statusText}=require('./protocol');
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,label){for(let i=0;i<200;i++){if(check())return;await delay(10);}throw Error('timeout: '+label);}
function editor(home) {
  const handlers={},intervals=[],timers=new Set(),sockets=[],status={text:'',show(){},dispose(){}};
  let enabled=true,largestChunk=0,renderedFrames=0,tooltip;
  Object.defineProperty(status,'tooltip',{get(){return tooltip;},set(value){tooltip=value;renderedFrames++;}});
  const subscribe=name=>fn=>{handlers[name]=fn;return{dispose(){delete handlers[name];}};};
  const vscode={StatusBarAlignment:{Left:1},env:{appName:'Visual Studio Code'},
    workspace:{isTrusted:true,getConfiguration(){return{get(){return enabled;}};},onDidChangeTextDocument:subscribe('edit'),onDidChangeConfiguration:subscribe('configuration'),onDidGrantWorkspaceTrust:subscribe('trust')},
    window:{state:{focused:true},createStatusBarItem(){return status;},onDidChangeWindowState:subscribe('focus'),onDidChangeTextEditorSelection:subscribe('selection'),onDidChangeTextEditorVisibleRanges:subscribe('scroll')}};
  const context={subscriptions:[]},module={exports:{}};
  const sandbox={module,Buffer,process:{platform:process.platform},require(name){
    if(name==='vscode')return vscode;
    if(name==='node:os')return{homedir(){return home;}};
    if(name==='node:net')return{createConnection(options){
      assert.equal(options.path,path.join(home,'Library','Application Support','ContextOS Observation Candidate','observations.sock'));
      const socket=net.createConnection(options);sockets.push(socket);
      socket.on('data',bytes=>{largestChunk=Math.max(largestChunk,bytes.length);});return socket;
    }};
    if(name==='./protocol')return require('./protocol');return require(name);
  },setTimeout(fn,ms){
    if(ms===250){const timer=setTimeout(()=>{timers.delete(timer);fn();},ms);timers.add(timer);return timer;}
    return{synthetic:true,fn,ms};
  },clearTimeout(timer){if(!timer?.synthetic){clearTimeout(timer);timers.delete(timer);}},setInterval(fn){intervals.push(fn);return fn;},clearInterval(){}};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'extension.js'),'utf8'),sandbox,{filename:'reviewed-extension.js'});
  module.exports.activate(context);
  return{status,sockets,get renderedFrames(){return renderedFrames;},get largestChunk(){return largestChunk;},heartbeat(){intervals.forEach(fn=>fn());},
    focus(value){vscode.window.state.focused=value;handlers.focus({focused:value});},
    edit(){handlers.edit({contentChanges:[new Proxy({}, {get(){throw Error('content inspected');}})],get document(){throw Error('document inspected');}});},
    signal(name){handlers[name](new Proxy({}, {get(){throw Error('position or range inspected');}}));},
    dispose(){enabled=false;for(const sub of context.subscriptions)sub.dispose();module.exports.deactivate();for(const t of timers)clearTimeout(t);}};
}

test('isolated cross-process activation, shared values, multi-window union, idle, resume and persisted restore',async()=>{
  assert.equal(process.platform,'darwin');
  const repo=path.resolve(__dirname,'../..'),binary=process.env.CONTEXTOS_TEST_HOST||path.join(repo,'.build/debug/contextos-bridge-integration-host');
  const home=fs.mkdtempSync('/tmp/cxi-'),directory=path.join(home,'Library','Application Support','ContextOS Observation Candidate');
  fs.mkdirSync(directory,{recursive:true,mode:0o700});
  const child=spawn(binary,[directory],{stdio:['pipe','pipe','pipe']});
  const events=[],replies=new Map(),clients=[],checks=[];let next=0,stderr='';
  child.stderr.on('data',b=>{stderr+=b.toString();});
  const lines=readline.createInterface({input:child.stdout});
  lines.on('line',line=>{const e=JSON.parse(line);events.push(e);if(e.type==='reply')replies.set(e.request,e);});
  async function rpc(action,at){const request=String(++next);child.stdin.write(JSON.stringify({action,at,request})+'\n');await until(()=>replies.has(request),action);const reply=replies.get(request);assert.equal(reply.error,undefined);return reply.snapshot;}
  async function packet(kind,count){await until(()=>events.filter(e=>e.type==='packet'&&e.kind===kind).length>=count,kind);}
  async function same(snapshot,...windows){await until(()=>windows.every(w=>w.status.text===statusText(snapshot)),'same status aggregate');}
  try {
    await until(()=>fs.existsSync(path.join(directory,'observations.sock')),'test socket');
    const a=editor(home);clients.push(a);await packet('focus',1);
    let s=await rpc('advance',10);assert.equal(s.estimatedNanoseconds,10e9);await same(s,a);checks.push('activation and real bidirectional Unix socket');
    a.edit();await packet('edits',1);a.signal('selection');await packet('activity',1);checks.push('privacy guards on synthetic document and position payloads');
    await rpc('advance',20);const b=editor(home);clients.push(b);await packet('focus',2);
    s=await rpc('advance',30);assert.equal(s.estimatedNanoseconds,30e9);await same(s,a,b);
    a.focus(false);await packet('focus',3);s=await rpc('advance',40);assert.equal(s.estimatedNanoseconds,40e9);checks.push('overlap union and late blur do not duplicate or stop current window');
    for(let t=60;t<=330;t+=30){await rpc('advance',t);const n=events.filter(e=>e.type==='packet'&&e.kind==='heartbeat').length;b.heartbeat();await packet('heartbeat',n+1);}
    s=await rpc('snapshot');assert.equal(s.estimatedNanoseconds,320e9);assert.equal(s.phase,'paused');await same(s,a,b);
    s=await rpc('advance',360);assert.equal(s.estimatedNanoseconds,320e9);checks.push('300-second synthetic idle cutoff; heartbeat does not extend activity');
    b.signal('scroll');await packet('activity',2);s=await rpc('advance',361);assert.equal(s.estimatedNanoseconds,321e9);assert.equal(s.phase,'active');await same(s,a,b);checks.push('new scroll signal resumes without filling idle gap');
    await rpc('save');const file=path.join(directory,'activity-day-v1.json'),stored=JSON.parse(fs.readFileSync(file,'utf8'));
    assert.equal(stored.estimatedNanoseconds,321e9);assert.ok(fs.statSync(file).size<=16384);assert.equal(fs.statSync(file).mode&0o777,0o600);
    assert.deepEqual(Object.keys(stored).sort(),['version','day','timeZoneID','estimatedNanoseconds','phase','partial','idleSeconds','generatedAt'].sort());
    await rpc('interrupt',370);await rpc('restore',1000);s=await rpc('advance',1010);assert.equal(s.estimatedNanoseconds,321e9);assert.equal(s.phase,'paused');assert.equal(s.partial,true);checks.push('production aggregate store and simulated ledger restart do not restore open intervals');
    b.signal('selection');await packet('activity',3);s=await rpc('advance',1011);assert.equal(s.estimatedNanoseconds,322e9);
    b.dispose();await until(()=>events.some(e=>e.type==='disconnected'),'actual socket close');const c=editor(home);clients.push(c);await packet('focus',4);
    s=await rpc('advance',1012);assert.equal(s.estimatedNanoseconds,323e9);await same(s,a,c);checks.push('actual disconnect and new connection resume from a new signal');
    const beforeA=a.renderedFrames,beforeC=c.renderedFrames;
    await Promise.all(Array.from({length:20},()=>rpc('snapshot')));
    await until(()=>a.renderedFrames>=beforeA+20&&c.renderedFrames>=beforeC+20,'all real Unix burst frames rendered');await same(s,a,c);
    assert.ok(!a.sockets[0].destroyed&&!c.sockets[0].destroyed);checks.push('20-frame production host burst preserves connections; >2KiB coalescence is a separate deterministic unit fixture');
    const report={scope:'real Unix IPC and production Swift ledger/store; mocked VS Code API and synthetic monotonic clock',gui:false,realExtensionHost:false,realUserActivity:false,productionUserSettingsTouched:false,productionSocketOrAggregateTouched:false,checks,finalEstimatedNanoseconds:s.estimatedNanoseconds,largestRealSocketChunk:Math.max(...clients.map(w=>w.largestChunk)),temporaryStoreBytes:fs.statSync(file).size};
    const out=path.join(repo,'artifacts/bridge-cross-process-integration.json');fs.writeFileSync(out,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
  } finally {
    clients.forEach(w=>w.dispose());child.stdin.write(JSON.stringify({action:'quit'})+'\n');child.stdin.end();
    await until(()=>child.exitCode!==null||child.signalCode!==null,'test host exit').catch(()=>{child.kill('SIGTERM');});
    lines.close();fs.rmSync(home,{recursive:true,force:true});
  }
  assert.equal(child.exitCode,0,stderr);
});
