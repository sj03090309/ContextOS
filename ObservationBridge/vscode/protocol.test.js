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
