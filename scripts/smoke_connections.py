#!/usr/bin/env python3
"""CLI integration smoke tests using a disposable Foundation home only."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

parser=argparse.ArgumentParser()
parser.add_argument('--binary',required=True,type=pathlib.Path)
args=parser.parse_args()
binary=args.binary.resolve()
with tempfile.TemporaryDirectory(prefix='contextos-cli-home-') as directory:
    home=pathlib.Path(directory)
    env=dict(os.environ,CFFIXED_USER_HOME=str(home))
    def run(*arguments,success=True):
        result=subprocess.run([str(binary),*arguments],env=env,capture_output=True,text=True,timeout=30)
        assert (result.returncode==0)==success,(arguments,result.stdout,result.stderr)
        assert 'DUMMY_PRIVATE_VALUE' not in result.stdout+result.stderr
        return result
    def snapshot():
        return {str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in home.rglob('*') if p.is_file() and '.contextos-backups' not in p.parts}
    (home/'.claude.json').write_text('{"user_key":"DUMMY_PRIVATE_VALUE","mcpServers":{"other":{"command":"keep"}}}')
    (home/'.codex').mkdir()
    (home/'.codex/config.toml').write_text('# keep my comments\nmodel="fixture"\n[mcp_servers.other]\ncommand="keep"\n')
    before=snapshot()
    run('connect','--agent','Claude Code'); run('connect','--agent','Codex')
    assert snapshot()==before
    assert not (home/'.contextos-backups').exists()
    for agent in ['Claude Code','Codex']:
        run('connect','--agent',agent,'--apply')
        connected=snapshot()
        run('connect','--agent',agent,'--apply')
        assert snapshot()==connected
        run('disconnect','--agent',agent,'--apply')
        disconnected=snapshot()
        run('disconnect','--agent',agent,'--apply')
        assert snapshot()==disconnected
        run('restore-settings','--agent',agent,'--apply')
        assert snapshot()==connected
        run('restore-settings','--agent',agent,'--apply')
        assert snapshot()==connected
    assert json.loads((home/'.claude.json').read_text())['user_key']=='DUMMY_PRIVATE_VALUE'
    assert '# keep my comments' in (home/'.codex/config.toml').read_text()
    (home/'.claude/settings.json').write_text('{"secret":"DUMMY_PRIVATE_VALUE",')
    before=snapshot()
    run('connect','--agent','Claude Code','--apply',success=False)
    assert snapshot()==before
print('CLI smoke passed: preview/cancel, connect repetition, disconnect, restore, malformed settings; temporary home only.')
