import Foundation

/// A session-scoped stdio tool, installed alongside the existing status sidecar.
/// Commands are atomically queued; the host persists changes before acknowledging them.
enum AttentionAgent {
    static var directory: URL {
        ClaudeStatusSidecar.supportDirectory.appendingPathComponent("attention", isDirectory: true)
    }
    static var scriptURL: URL { directory.appendingPathComponent("udha-attention.py") }
    static func mailbox(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    static func install() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    }
    static func arguments(for tool: SessionTool?, sessionID: UUID) throws -> [String] {
        guard tool == .claude || tool == .codex else { return [] }
        try install()
        let box = mailbox(sessionID)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try configurationArguments(for: tool, scriptPath: scriptURL.path, mailboxPath: box.path)
    }
    static func configurationArguments(for tool: SessionTool?, scriptPath: String, mailboxPath: String) throws -> [String] {
        let args = [scriptPath, mailboxPath]
        if tool == .claude {
            let config: [String: Any] = ["mcpServers": ["udha_attention": ["command": "python3", "args": args]]]
            let data = try JSONSerialization.data(withJSONObject: config)
            return ["--mcp-config", String(decoding: data, as: UTF8.self)]
        }
        // TOML does not accept JSON's optional escaped slash (\/).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let encoded = String(decoding: try encoder.encode(args), as: UTF8.self)
        return ["-c", "mcp_servers.udha_attention.command=\"python3\"",
                "-c", "mcp_servers.udha_attention.args=\(encoded)"]
    }
    static let script = #"""
#!/usr/bin/env python3
"""Session-scoped MCP transport for Udha. Uses only the Python standard library."""
import json
import os
from pathlib import Path
import sys
import time
import uuid

mailbox = Path(sys.argv[1])
mailbox.mkdir(parents=True, exist_ok=True, mode=0o700)

def submit(action, arguments):
    request_id = str(uuid.uuid4())
    payload = dict(arguments, action=action, commandID=request_id, createdAt=time.time())
    tmp = mailbox / (request_id + '.tmp')
    tmp.write_text(json.dumps(payload))
    os.replace(tmp, mailbox / (request_id + '.json'))
    response = mailbox / (request_id + '.reply')
    for _ in range(80):
        if response.exists():
            value = json.loads(response.read_text())
            response.unlink(missing_ok=True)
            return value
        time.sleep(0.1)
    return {'ok': False, 'message': 'Udha has not acknowledged this request yet. It is queued; do not submit duplicates.'}

TOOLS = [
    {'name': 'request_attention',
     'description': 'Tell the user that this Udha session needs their attention. Use only for a concrete decision, approval, blocker, or artifact ready for review. Summarize what the user must do; never forward rhetorical questions or routine progress. Decision/approval/blocked can send a push notification. Do not request approval already granted. Return to the user after a blocking request. Use task_completed for completion.',
     'inputSchema': {'type': 'object', 'properties': {
         'kind': {'type': 'string', 'enum': ['decision', 'approval', 'blocked', 'review']},
         'summary': {'type': 'string', 'minLength': 1, 'maxLength': 180},
         'detail': {'type': 'string', 'maxLength': 2000},
         'url': {'type': 'string', 'description': 'Optional http(s) preview, PR, or artifact URL.'}},
         'required': ['kind', 'summary'], 'additionalProperties': False}},
    {'name': 'resolve_attention',
     'description': 'Resolve a previous attention request when answered or no longer relevant. Pass the event ID returned by request_attention.',
     'inputSchema': {'type': 'object', 'properties': {'eventID': {'type': 'string'}}, 'required': ['eventID'], 'additionalProperties': False}},
    {'name': 'task_completed',
     'description': 'Report that the user-requested task is complete, with a concise result and optional review URL. Call once at the end of the task, after verification. This satisfies Notify when done; it does not send unsolicited completion pushes unless enabled by the user.',
     'inputSchema': {'type': 'object', 'properties': {
         'summary': {'type': 'string', 'minLength': 1, 'maxLength': 180},
         'url': {'type': 'string'}}, 'required': ['summary'], 'additionalProperties': False}}
]

def dispatch(method, params):
    if method == 'initialize':
        return {'protocolVersion': params.get('protocolVersion', '2024-11-05'),
                'capabilities': {'tools': {}}, 'serverInfo': {'name': 'udha-attention', 'version': '1.0.0'},
                'instructions': 'Use Udha attention tools for real decisions or blockers and report task_completed once the requested work is verified. Never use them for routine progress. Resuming work after an answer should resolve the earlier attention request.'}
    if method == 'ping':
        return {}
    if method == 'tools/list':
        return {'tools': TOOLS}
    if method == 'tools/call':
        name = params.get('name')
        args = params.get('arguments', {})
        if not isinstance(args, dict):
            raise ValueError('arguments must be an object')
        if name not in [t['name'] for t in TOOLS]:
            raise ValueError('Unknown tool')
        if name != 'resolve_attention':
            if not isinstance(args.get('summary'), str) or not args['summary'].strip() or len(args['summary']) > 180:
                raise ValueError('summary must be 1–180 characters')
            if name == 'request_attention' and args.get('kind') not in ['decision', 'approval', 'blocked', 'review']:
                raise ValueError('Invalid attention kind')
        elif not isinstance(args.get('eventID'), str):
            raise ValueError('eventID is required')
        result = submit(name, args)
        return {'content': [{'type': 'text', 'text': json.dumps(result)}], 'isError': not result.get('ok', False)}
    raise LookupError('Method not found')

for line in sys.stdin:
    req = None
    try:
        if len(line) > 65536:
            raise ValueError('Request too large')
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError('Expected an object')
        if 'id' not in req:
            continue
        result = dispatch(req.get('method'), req.get('params') or {})
        response = {'jsonrpc': '2.0', 'id': req['id'], 'result': result}
    except Exception as exc:
        response = {'jsonrpc': '2.0', 'id': req.get('id') if isinstance(req, dict) else None,
                    'error': {'code': -32601 if isinstance(exc, LookupError) else -32602, 'message': str(exc)}}
    print(json.dumps(response), flush=True)

"""#
}
