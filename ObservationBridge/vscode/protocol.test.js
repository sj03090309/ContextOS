'use strict';
const test = require('node:test'); const assert = require('node:assert/strict');
const {PacketEncoder, hasContentChange} = require('./protocol');
test('does not access document, URI, text or change contents', () => {
  const changes = [new Proxy({}, {get(){throw Error('content read');}})];
  const event = {contentChanges: changes, get document(){throw Error('document read');}};
  assert.equal(hasContentChange(event), true); assert.equal(hasContentChange({contentChanges: []}), false);
});
test('exact packet schema excludes clocks and private content', () => {
  const p = new PacketEncoder('vscode', '12345678-1234-1234-1234-123456789abc');
  const focus = JSON.parse(p.frame('focus', false)), edit = JSON.parse(p.frame('edits', 2));
  assert.deepEqual(Object.keys(focus).sort(), ['version','editor','nonce','sequence','kind','focused'].sort());
  assert.equal(focus.focused, false); assert.equal(edit.sequence, 2); assert.equal(edit.count, 2);
});
test('batch bound and count-only event semantics', () => {
  const p = new PacketEncoder('vscode');
  assert.throws(() => p.frame('edits', 0)); assert.throws(() => p.frame('edits', 257));
  assert.equal(JSON.parse(p.frame('edits', 256)).count, 256);
});
test('status bar uses host value without a client timer or extrapolation',()=>{
  const {decodeSnapshot,statusText}=require('./protocol');
  const s={version:1,day:'2026-10-14',timeZoneID:'Asia/Seoul',estimatedNanoseconds:9032000000000,phase:'active',partial:false,idleSeconds:300,generatedAt:1};
  assert.equal(statusText(decodeSnapshot(JSON.stringify(s))),'$(watch) 02:30:32 · 활동 추정');
  assert.match(statusText({...s,phase:'paused'}),/일시정지/);
  assert.match(statusText(s,true),/연결 끊김/);
  assert.throws(()=>decodeSnapshot(JSON.stringify({...s,text:'secret'})));
  assert.throws(()=>decodeSnapshot(JSON.stringify({...s,estimatedNanoseconds:-1})));
  assert.match(statusText({...s,estimatedNanoseconds:undefined}),/—/);
});
test('stream decoder accepts fragmented UTF-8 and bounds incomplete frames',()=>{
  const {SnapshotStreamDecoder}=require('./protocol');
  const s={version:1,day:'2026-10-15',timeZoneID:'테스트',estimatedNanoseconds:0,phase:'paused',partial:true,idleSeconds:300,generatedAt:1};
  const bytes=Buffer.from(JSON.stringify(s)+'\n'),cut=bytes.indexOf(Buffer.from('테'))+1,decoder=new SnapshotStreamDecoder();
  assert.deepEqual(decoder.push(bytes.subarray(0,cut)),[]);
  assert.deepEqual(decoder.push(bytes.subarray(cut)),[s]);
  const count=Math.floor(60000/bytes.length);
  assert.equal(new SnapshotStreamDecoder().push(Buffer.concat(Array(count).fill(bytes))).length,count);
  assert.throws(()=>new SnapshotStreamDecoder().push(Buffer.alloc(1025,120)));
  assert.throws(()=>new SnapshotStreamDecoder().push(Buffer.alloc(65537,120)));
});
