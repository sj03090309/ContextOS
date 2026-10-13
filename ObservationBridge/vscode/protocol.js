'use strict';
const {randomUUID} = require('node:crypto');
class PacketEncoder {
  constructor(editor, nonce = randomUUID()) { this.editor = editor; this.nonce = nonce; this.sequence = 0; }
  frame(kind, value) {
    const packet = {version: 1, editor: this.editor, nonce: this.nonce, sequence: ++this.sequence, kind};
    if (kind === 'focus') packet.focused = value === true;
    if (kind === 'edits') {
      if (!Number.isInteger(value) || value < 1 || value > 256) throw new RangeError('count');
      packet.count = value;
    }
    return JSON.stringify(packet) + '\n';
  }
}
// Reads only array length. Does not touch entries, text, document, URI or author.
function hasContentChange(event) { return Array.isArray(event.contentChanges) && event.contentChanges.length > 0; }
module.exports = {PacketEncoder, hasContentChange};
