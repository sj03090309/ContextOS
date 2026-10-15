'use strict';
const vscode=require('vscode'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
exports.run=async()=>{
  const ext=vscode.extensions.getExtension('contextos.observation-bridge');assert.ok(ext);
  const result={actualExtensionHost:true,realVSCodeApi:true,syntheticDocument:true,realUserActivity:false,bridgeConnectionEnabled:false,physicalScreenVerified:false};
  let subscription;
  try{
    assert.equal(vscode.workspace.getConfiguration('contextosObservation').get('enabled'),false);
    assert.equal(vscode.workspace.workspaceFolders,undefined);
    await ext.activate();assert.equal(ext.isActive,true);
    for(const key of ['createStatusBarItem','onDidChangeWindowState','onDidChangeTextEditorSelection','onDidChangeTextEditorVisibleRanges'])assert.equal(typeof vscode.window[key],'function');
    const doc=await vscode.workspace.openTextDocument({language:'plaintext',content:'Synthetic ContextOS Extension Host fixture\n'});
    let edits=0;
    subscription=vscode.workspace.onDidChangeTextDocument(e=>{if(e.document===doc&&e.contentChanges.length)edits++;});
    const edit=new vscode.WorkspaceEdit();edit.insert(doc.uri,new vscode.Position(0,0),'synthetic edit\n');
    assert.equal(await vscode.workspace.applyEdit(edit),true);
    for(let i=0;edits===0&&i<200;i++)await new Promise(r=>setTimeout(r,10));
    assert.ok(edits>0);
    Object.assign(result,{passed:true,extensionActive:true,version:ext.packageJSON.version,vscodeVersion:vscode.version,realEditCallbacks:edits,sourceHash:crypto.createHash('sha256').update(fs.readFileSync(path.join(ext.extensionPath,'extension.js'))).digest('hex')});
  }catch(error){result.passed=false;result.error=String(error);throw error;}
  finally{if(subscription)subscription.dispose();const output=path.join(ext.extensionPath,'result.json');fs.writeFileSync(output+'.tmp',JSON.stringify(result,null,2)+'\n');fs.renameSync(output+'.tmp',output);}
};
