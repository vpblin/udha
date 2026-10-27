"""Exercise the bundled MCP server without invoking a model or a live Udha session."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

source = (Path(__file__).resolve().parents[1] / 'Udha.AIDesktop/Sessions/AttentionAgent.swift').read_text()
script = source.split('static let script = #"""\n', 1)[1].rsplit('\n"""#', 1)[0]
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    path = root / 'attention.py'
    path.write_text(script)
    mailbox = root / 'mailbox'
    process = subprocess.Popen(['python3', str(path), str(mailbox)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    def send(value):
        process.stdin.write(json.dumps(value) + '\n')
        process.stdin.flush()
    def read():
        return json.loads(process.stdout.readline())
    try:
        send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05'}})
        assert read()['result']['serverInfo']['name'] == 'udha-attention'
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        names = {tool['name'] for tool in read()['result']['tools']}
        assert names == {'request_attention', 'resolve_attention', 'task_completed'}
        send({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {
            'name': 'request_attention', 'arguments': {'kind': 'decision', 'summary': 'Keep an archive?'}}})
        for _ in range(100):
            jobs = list(mailbox.glob('*.json'))
            if jobs:
                break
            time.sleep(.02)
        assert jobs, 'tool must queue a host command'
        command = json.loads(jobs[0].read_text())
        assert command['action'] == 'request_attention'
        assert command['summary'] == 'Keep an archive?'
        assert 'sessionId' not in command, 'tool is scoped by its mailbox, not model input'
        jobs[0].with_suffix('.reply').write_text(json.dumps({'ok': True, 'eventID': command['commandID']}))
        response = read()['result']
        assert response['isError'] is False
        assert json.loads(response['content'][0]['text'])['eventID'] == command['commandID']
        send({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {
            'name': 'request_attention', 'arguments': {'kind': 'routine_progress', 'summary': 'Still working'}}})
        assert 'error' in read(), 'routine progress is not an attention event'
        send({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call', 'params': {
            'name': 'task_completed', 'arguments': {'summary': ''}}})
        assert 'error' in read(), 'empty completion cannot create an event'
        send({'jsonrpc': '2.0', 'id': 6, 'method': 'ping'})
        assert read()['result'] == {}
        print('PASS MCP: initialize, discovery, session-scoped queue, host acknowledgement, invalid inputs, ping')
    finally:
        process.stdin.close()
        process.wait(timeout=3)
        assert process.returncode == 0, process.stderr.read()
