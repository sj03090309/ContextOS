'use strict';
const {randomUUID} = require('node:crypto');
const {StringDecoder} = require('node:string_decoder');
class PacketEncoder {
  constructor(editor, nonce = randomUUID()) { this.editor = editor; this.nonce = nonce; this.sequence = 0; }
  frame(kind, value, focused) {
    const packet = {version: 2, editor: this.editor, nonce: this.nonce, sequence: ++this.sequence, kind};
    if (kind === 'focus') packet.focused = value === true;
    if (kind === 'edits') {
      if (!Number.isInteger(value) || value < 1 || value > 256) throw new RangeError('count');
      packet.count = value; packet.focused = focused === true;
    }
    if (kind === 'activity') {
      if (!['selection','scroll'].includes(value)) throw new RangeError('activity');
      packet.activity = value; packet.focused = focused === true;
    }
    return JSON.stringify(packet) + '\n';
  }
}
function hasContentChange(event) { return Array.isArray(event.contentChanges) && event.contentChanges.length > 0; }
function decodeSnapshot(data) {
  if (Buffer.byteLength(data) > 1024) throw Error('size');
  const s = JSON.parse(data);
  const keys = ['version','day','timeZoneID','estimatedNanoseconds','phase','partial','idleSeconds','generatedAt'];
  if (!s || Object.keys(s).some(k=>!keys.includes(k)) || s.version!==1 || s.idleSeconds!==300 ||
      typeof s.day!=='string' || !/^\d{4}-\d{2}-\d{2}$/.test(s.day) || typeof s.timeZoneID!=='string' || s.timeZoneID.length>128 ||
      !['active','paused','notObserved'].includes(s.phase) || typeof s.partial!=='boolean' || !Number.isFinite(s.generatedAt) ||
      (s.estimatedNanoseconds!=null && (!Number.isSafeInteger(s.estimatedNanoseconds) || s.estimatedNanoseconds<0 || s.estimatedNanoseconds>93600000000000))) throw Error('schema');
  return s;
}
class SnapshotStreamDecoder {
  constructor(){this.pending='';this.utf8=new StringDecoder('utf8');}
  push(data){
    if(data.length>65536)throw Error('chunk size');
    const text=this.utf8.write(data),frames=[];let start=0,index;
    while((index=text.indexOf('\n',start))>=0){
      const part=text.slice(start,index);
      if(Buffer.byteLength(this.pending)+Buffer.byteLength(part)>1024)throw Error('frame size');
      frames.push(decodeSnapshot(this.pending+part));this.pending='';start=index+1;
    }
    const tail=text.slice(start);
    if(Buffer.byteLength(this.pending)+Buffer.byteLength(tail)>1024)throw Error('frame size');
    this.pending+=tail;return frames;
  }
}
function statusText(s, disconnected=false) {
  let value='—';
  if (s && s.estimatedNanoseconds!=null) {
    const seconds=Math.floor(s.estimatedNanoseconds/1e9);
    value=[Math.floor(seconds/3600),Math.floor(seconds/60)%60,seconds%60].map(x=>String(x).padStart(2,'0')).join(':');
  }
  return `$(watch) ${value} · ${disconnected?'연결 끊김':s&&s.phase==='paused'?'일시정지 · 추정':'활동 추정'}`;
}
module.exports = {PacketEncoder, hasContentChange, decodeSnapshot, statusText, SnapshotStreamDecoder};
