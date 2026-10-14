'use strict';
const vscode = require('vscode');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const {PacketEncoder, hasContentChange, decodeSnapshot, statusText} = require('./protocol');
let stop;
function activate(context) {
  const status=vscode.window.createStatusBarItem('contextos.activity',vscode.StatusBarAlignment.Left,1);
  status.name='ContextOS 오늘 활동 추정';status.text=statusText();status.tooltip='확장 연결 후 자동 집계합니다. 실제 코딩·생각 시간의 실측이 아닙니다.';status.show();
  context.subscriptions.push(status);
  function configure() {
    if (stop) stop(); stop = undefined;
    status.text=statusText();
    if (process.platform !== 'darwin' || vscode.env.remoteName || !vscode.workspace.isTrusted ||
        !vscode.workspace.getConfiguration('contextosObservation').get('enabled', false)) return;
    const subscriptions=[];let socket,encoder,retry,batch,heartbeat,stale,pending=0,activity,loss=false,disposed=false,buffer='',lastSnapshot;
    let lastFocus=vscode.window.state.focused;
    const socketPath=path.join(os.homedir(),'Library','Application Support','ContextOS Observation Candidate','observations.sock');
    function send(kind,value,focused) {
      if (!socket||!encoder||socket.destroyed||socket.writableLength>4096) {loss=true;return false;}
      socket.write(encoder.frame(kind,value,focused));return true;
    }
    function flush() {
      clearTimeout(batch);batch=undefined;
      if(loss&&send('gap'))loss=false;
      const focused=vscode.window.state.focused;
      if(pending){send('edits',pending,focused);pending=0;activity=undefined;}
      else if(activity){send('activity',activity,focused);activity=undefined;}
    }
    function mark(kind) {
      if(!socket||socket.destroyed||!encoder){loss=true;return;}
      if(kind==='edit'){if(pending<256)pending++;else loss=true;}
      else activity=kind;
      if(!batch)batch=setTimeout(flush,250);
    }
    function connect() {
      if(disposed)return;
      buffer='';socket=net.createConnection({path:socketPath});
      socket.on('connect',()=>{
        encoder=new PacketEncoder(vscode.env.appName.includes('Insiders')?'vscode-insiders':'vscode');
        if(loss)send('gap');loss=false;
        lastFocus=vscode.window.state.focused;send('focus',lastFocus);
      });
      socket.on('data',data=>{
        buffer+=data.toString('utf8');
        if(Buffer.byteLength(buffer)>2048){socket.destroy();return;}
        let index;
        while((index=buffer.indexOf('\n'))>=0){
          const line=buffer.slice(0,index);buffer=buffer.slice(index+1);
          try {
            lastSnapshot=decodeSnapshot(line);status.text=statusText(lastSnapshot);
            status.tooltip=`오늘 활동 추정 · ${lastSnapshot.timeZoneID}\n포커스/편집/커서/스크롤 후 최대 5분, 이후 자동 정지. 읽기·생각·사람/AI를 정확히 구분하지 못합니다.\n${lastSnapshot.partial?'일부 관측 누락 · ':''}중앙 앱과 같은 마지막 집계값. 연결이 없을 때 시간을 늘리지 않습니다.`;
            clearTimeout(stale);stale=setTimeout(()=>{status.text=statusText(lastSnapshot,true);},45000);
          }catch{socket.destroy();return;}
        }
      });
      socket.on('error',()=>{loss=true;});
      socket.on('close',()=>{encoder=undefined;clearTimeout(stale);status.text=statusText(lastSnapshot,true);if(!disposed)retry=setTimeout(connect,30000);});
    }
    subscriptions.push(vscode.workspace.onDidChangeTextDocument(event=>{if(hasContentChange(event))mark('edit');}));
    // Ignore payloads entirely: no document/URI, cursor positions or scroll ranges.
    subscriptions.push(vscode.window.onDidChangeTextEditorSelection(()=>mark('selection')));
    subscriptions.push(vscode.window.onDidChangeTextEditorVisibleRanges(()=>mark('scroll')));
    subscriptions.push(vscode.window.onDidChangeWindowState(state=>{
      if(state.focused===lastFocus)return;flush();lastFocus=state.focused;send('focus',lastFocus);
    }));
    heartbeat=setInterval(()=>send('heartbeat'),30000);connect();
    stop=()=>{disposed=true;for(const sub of subscriptions)sub.dispose();clearTimeout(retry);clearTimeout(batch);clearTimeout(stale);clearInterval(heartbeat);pending=0;activity=undefined;if(socket)socket.destroy();};
  }
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(event=>{if(event.affectsConfiguration('contextosObservation.enabled'))configure();}));
  context.subscriptions.push(vscode.workspace.onDidGrantWorkspaceTrust(configure));
  context.subscriptions.push({dispose:()=>{if(stop)stop();stop=undefined;}});configure();
}
function deactivate(){if(stop)stop();stop=undefined;}
module.exports={activate,deactivate};
