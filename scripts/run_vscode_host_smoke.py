#!/usr/bin/env python3
"""Official installed-VS Code test flags, no new runner install or real bridge.
A separate Development Host window may briefly appear. Only a disposable profile
is configured. Neither HOME nor the user's settings/aggregate are changed.
"""
import datetime,json,os,pathlib,shutil,signal,subprocess,tempfile,time
repo=pathlib.Path(__file__).resolve().parents[1]
root=pathlib.Path(tempfile.mkdtemp(prefix='contextos-vscode-host-',dir='/tmp'))
fixture=root/'extension';fixture.mkdir()
source=repo/'ObservationBridge/vscode'
for name in ['extension.js','protocol.js','README.md','LICENSE']:
    shutil.copyfile(source/name,fixture/name)
manifest=json.loads((source/'package.json').read_text())
manifest['activationEvents']=[]
(fixture/'package.json').write_text(json.dumps(manifest))
shutil.copyfile(repo/'TestSupport/VSCodeExtensionHost/smoke.cjs',fixture/'smoke.cjs')
settings=root/'user-data/User';settings.mkdir(parents=True)
(settings/'settings.json').write_text(json.dumps({'contextosObservation.enabled':False,'telemetry.telemetryLevel':'off','update.mode':'none','extensions.autoUpdate':False,'extensions.autoCheckUpdates':False,'workbench.enableExperiments':False,'chat.disableAIFeatures':True,'window.restoreWindows':'none'}))
(root/'extensions').mkdir()
args=['/usr/local/bin/code','--user-data-dir',str(root/'user-data'),'--extensions-dir',str(root/'extensions'),'--new-window','--disable-extensions','--skip-welcome','--skip-release-notes','--skip-add-to-recently-opened','--extensionDevelopmentPath='+str(fixture),'--extensionTestsPath='+str(fixture/'smoke.cjs')]
report={'run_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'isolated_root':str(root),'runner':'official installed VS Code CLI','download_or_install':False,'production_settings_changed':False,'production_socket_or_aggregate_used':False}
log=repo/'artifacts/vscode-extension-host-smoke.log'
assertion=subprocess.Popen(['/usr/bin/caffeinate','-d','-i','-t','90'])
try:
    with log.open('wb') as output:
        proc=subprocess.Popen(args,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            report['cli_exit_code']=proc.wait(timeout=45)
            # macOS CLI may return before the Development Host finishes.
            deadline=time.monotonic()+40
            while report['cli_exit_code']==0 and not (fixture/'result.json').exists() and time.monotonic()<deadline:
                time.sleep(0.1)
        except subprocess.TimeoutExpired:
            report['timeout']=True
            os.killpg(proc.pid,signal.SIGTERM)
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:report['cli_still_running']=True
finally:
    assertion.terminate();assertion.wait(timeout=5)
    report['owned_sleep_prevention_released']=True
result=fixture/'result.json'
if result.exists():report['result']=json.loads(result.read_text())
else:report['result_missing']=True
# Test CLI startup may be asynchronous; never delete a profile still in use.
for attempt in range(21):
    processes=subprocess.run(['/bin/ps','-axo','pid=,args='],capture_output=True,text=True)
    matches=[line for line in processes.stdout.splitlines() if str(root) in line]
    if processes.returncode!=0 or not matches:break
    if attempt<20:time.sleep(0.25)
report['isolated_process_count']=len(matches) if processes.returncode==0 else None
if report.get('result',{}).get('passed') and processes.returncode==0 and not matches and root.resolve().as_posix().startswith('/private/tmp/contextos-vscode-host-'):
    shutil.rmtree(root);report['isolated_profile_removed']=True
else:report['isolated_profile_removed']=False
(repo/'artifacts/vscode-extension-host-smoke.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False))
