# ContextOS Observation Bridge — local candidate
Not installed. Disabled by default. VS Code / Insiders local macOS trusted windows only.

When explicitly enabled, counts `onDidChangeTextDocument` callbacks whose `contentChanges.length > 0` and observes window focus. One callback counts as one event regardless of change-array size. Human edits and AI/programmatic edits cannot be distinguished. No elapsed coding-time estimate is produced.

Sends version, static editor kind, random connection nonce, sequence, focus boolean or batched event count. Local Unix socket only: `~/Library/Application Support/ContextOS Observation Candidate/observations.sock`. A heartbeat contains only connection fields, no timestamp. Reconnection/loss is partial; gaps are not filled. Maximum batch 256 events; flush 250 ms, disconnected reconnect 30 seconds, heartbeat 60 seconds.

No text, document, URI, filename, window title, keys, language, project or credentials are read. No disk persistence, output log, telemetry or external network. The candidate host retains bounded counts in process memory only. The macOS host checks the peer UID; this is same-user access control, not signed extension provenance. Other software running as the same user could imitate packets.

Installation and enabling require separate user approval. No Accessibility, Input Monitoring or Apple credentials are required. To stop, disable `contextosObservation.enabled`, turn off the candidate app receiver, and uninstall `contextos.observation-bridge` from VS Code / Insiders. The stopped host removes its own socket; the empty candidate directory can be removed separately. No editor setting is changed by build/package scripts.
