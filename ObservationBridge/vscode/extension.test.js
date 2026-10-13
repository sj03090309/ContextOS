'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
function fixture(enabled=false,remote=false) {
  const handlers={},tasks=[],writes=[],disposed=[];let connections=0;
  const socket={destroyed:false,writableLength:0,on(name,fn){handlers[name]=fn;return this;},write(s){writes.push(JSON.parse(s));},destroy(){this.destroyed=true;}};
  const sub=name=>fn=>{handlers[name]=fn;return{dispose(){disposed.push(name);}};};
  const vscode={env:{remoteName:remote?'ssh-remote':undefined,appName:'Visual Studio Code'},
    workspace:{isTrusted:true,getConfiguration(){return{get(){return enabled;}};},
      onDidChangeTextDocument:sub('edit'),onDidChangeConfiguration:sub('configuration'),onDidGrantWorkspaceTrust:sub('trust')},
    window:{state:{focused:true},onDidChangeWindowState:sub('focus')}};
  const module={exports:{}};
  const sandbox={module,process:{platform:'darwin'},require(name){
    if(name==='vscode')return vscode;
    if(name==='node:net')return{createConnection(options){assert.equal(Object.keys(options).join(','),'path');connections++;return socket;}};
    if(name==='./protocol')return require('./protocol');return require(name);
  },setTimeout(fn,delay){const token={fn,delay};tasks.push(token);return token;},clearTimeout(){},setInterval(){return{};},clearInterval(){}};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'extension.js'),'utf8'),sandbox);
  module.exports.activate({subscriptions:[]});
  return{handlers,tasks,writes,disposed,get connections(){return connections;},disable(){enabled=false;handlers.configuration({affectsConfiguration:()=>true});}};
}
test('default off and remote windows create no socket or document subscription',()=>{
  for(const f of [fixture(),fixture(true,true)]){assert.equal(f.connections,0);assert.equal(f.handlers.edit,undefined);}
});
test('enabled adapter reads length only, batches counts and removes subscriptions',()=>{
  const f=fixture(true);assert.equal(f.connections,1);f.handlers.connect();
  f.handlers.edit({contentChanges:[],get document(){throw Error('private document read');}});
  assert.equal(f.tasks.length,0);
  f.handlers.edit({contentChanges:[new Proxy({}, {get(){throw Error('text read');}})],get document(){throw Error('document read');}});
  f.tasks.find(t=>t.delay===250).fn();
  assert.equal(f.writes.find(p=>p.kind==='edits').count,1);
  assert.equal(f.writes.length,2);assert.equal(f.writes[0].kind,'focus');
  f.disable();assert.ok(f.disposed.includes('edit')&&f.disposed.includes('focus'));
});
