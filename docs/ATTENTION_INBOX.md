# Attention inbox

Sessions now show explicit attention events instead of promoting the oldest parsed question. The inbox is shared by the phone, iPad, desktop, and headless host. Events can be opened, dismissed, or snoozed for 15 minutes. Preview actions accept only HTTP(S) URLs. Approvals open the session for review; a notification never executes an approval.

The bell on a session arms a one-shot **Notify when done** watch. Completion means an explicit agent `task_completed` report or a successful process exit, never a quiet terminal or the end of an assistant turn. The session menu also offers review/completion notification preferences. Decisions, approvals, and blockers notify by default; reviews and completions are quiet unless enabled or explicitly watched.

## Agent integration

New Claude and Codex sessions launched by the updated desktop or `udha-agent` receive a session-scoped stdio MCP server named `udha_attention`. This requires `python3` on the host's login PATH and respects the assistant's existing MCP approval policy. It does not change global Claude/Codex settings or add an LLM dependency.

- `request_attention(kind, summary, detail?, url?)`: decision, approval, blocked, or review. Returns a stable event ID.
- `resolve_attention(eventID)`: resolve a request that was answered or superseded.
- `task_completed(summary, url?)`: report verified task completion and satisfy a completion watch.

Tool descriptions instruct agents to use these for concrete actions, to resolve superseded requests, and to report completion once. Native approval phase changes also create and resolve events. Parsed prose never generates a push.

Existing assistant processes must start a new session to load the new MCP tool. The inbox, native approval detection, and dismissal work as soon as both apps are updated; existing processes do not retroactively gain tools. Plain shell sessions can satisfy a completion watch with a clean exit. Agent use of the explicit tools still depends on the assistant following their instructions.

## Persistence and transport

Each host owns its inbox in `Udha.AI/hooks/attention/inbox.json` under Application Support (the equivalent Foundation application-support directory on Linux). Session rows carry `attentionState`; `attention_events` advertises the capability. `attention_action` applies dismiss, snooze, resolve, watch, reviews, or completions on the owning host. Full snapshots and deltas synchronize both clients.

Commands are atomically queued in a session-specific mailbox and acknowledged after persistence. Command IDs and same-turn event summaries deduplicate retries. New input resolves actionable events, while review artifacts remain until dismissed. Live hook following does not replay old lifecycle events; a bounded recent-input scan reconciles inputs received while the host was closed. Reconnecting restores the inbox without replaying notification callbacks. A bounded archive retains dismissed event IDs.

The relay (`relay/`) preserves session/event/instance IDs in APNs payloads, groups notifications by session, and uses an event collapse ID plus a five-minute delivery expiration. Registered-device presence suppresses pushes while that phone is viewing the originating session; it expires after 45 seconds and is cleared when backgrounded. Refreshing the inbox removes delivered notifications for resolved/dismissed events. Taps open the current session state, not an old approval action.

## Rollout and verification

Build/install desktop and mobile, rebuild the headless host where used, and deploy the relay change for notification deep links and presence suppression. No production deployment or live APNs delivery is performed by the local test suite. Hosts must remain running/connected for live relay delivery; inbox persistence does not make APNs delivery guaranteed.

- Bundled MCP protocol: `python3 tests/attention_mcp_test.py`
- Desktop contract/lifecycle: `MOBILE=<mobile client checkout> bash tests/run.sh` (it builds the client's
  decoder as a module, so it needs that checkout; the mobile client is not part of this repository)
- Relay handlers/APNs payload: `node relay/tests/attention.test.js`, or `npm test` in `relay/` for the whole suite
- Build the app, and `swift build --package-path udha-agent`.

Integration references: [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Claude MCP configuration](https://code.claude.com/docs/en/mcp).
