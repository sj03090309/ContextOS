'use strict';
const vscode = require('vscode');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const {PacketEncoder, hasContentChange} = require('./protocol');
let stop;
function activate(context) {
  function configure() {
    if (stop) stop(); stop = undefined;
    if (process.platform !== 'darwin' || vscode.env.remoteName || !vscode.workspace.isTrusted ||
        !vscode.workspace.getConfiguration('contextosObservation').get('enabled', false)) return;
    const subscriptions = []; let socket, encoder, retry, batch, heartbeat, pending = 0, loss = false, disposed = false;
    const socketPath = path.join(os.homedir(), 'Library', 'Application Support', 'ContextOS Observation Candidate', 'observations.sock');
    function send(kind, value) {
      if (!socket || !encoder || socket.destroyed || socket.writableLength > 4096) { loss = true; return false; }
      socket.write(encoder.frame(kind, value)); return true;
    }
    function flush() {
      clearTimeout(batch); batch = undefined;
      if (loss && send('gap')) loss = false;
      if (pending) { send('edits', pending); pending = 0; }
    }
    function connect() {
      if (disposed) return;
      socket = net.createConnection({path: socketPath});
      socket.on('connect', () => {
        encoder = new PacketEncoder(vscode.env.appName.includes('Insiders') ? 'vscode-insiders' : 'vscode');
        send('focus', vscode.window.state.focused); if (loss) send('gap'); loss = false;
      });
      socket.on('error', () => { loss = true; });
      socket.on('close', () => { encoder = undefined; if (!disposed) retry = setTimeout(connect, 30000); });
    }
    subscriptions.push(vscode.workspace.onDidChangeTextDocument(event => {
      if (!hasContentChange(event)) return;
      if (!socket || socket.destroyed || !encoder) { loss = true; return; }
      if (pending < 256) pending++; else loss = true;
      if (!batch) batch = setTimeout(flush, 250);
    }));
    subscriptions.push(vscode.window.onDidChangeWindowState(state => { flush(); send('focus', state.focused); }));
    heartbeat = setInterval(() => send('heartbeat'), 60000);
    connect();
    stop = () => {
      disposed = true; for (const sub of subscriptions) sub.dispose();
      clearTimeout(retry); clearTimeout(batch); clearInterval(heartbeat);
      pending = 0; if (socket) socket.destroy();
    };
  }
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(event => {
    if (event.affectsConfiguration('contextosObservation.enabled')) configure();
  }));
  context.subscriptions.push(vscode.workspace.onDidGrantWorkspaceTrust(configure));
  context.subscriptions.push({dispose: () => { if (stop) stop(); stop = undefined; }});
  configure();
}
function deactivate() { if (stop) stop(); stop = undefined; }
module.exports = {activate, deactivate};
