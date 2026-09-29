# SPEC.md — VoiceChat

**A voice-driven, dual-pane, native macOS front end for multi-turn LLM conversations over the Model Context Protocol.**

| | |
|---|---|
| Document version | 2.3 — adds Talking Head presence over its spooler socket ([§9.5](#95-talking-head)) |
| Status | Implemented: the core loop, speech input and output, dictation and command mode, history, export, menu bar, Test Conversation, debates ([§17](#17-debate)), Talking Head, and the opt-in Streamable HTTP transport ([§4.7](#47-streamable-http-transport)). Not built: the Settings window. Ad-hoc signed, not notarised. |
| Supersedes | v1.0 (the original sketch, kept in [Appendix C](#appendix-c--original-specification-v10)) |
| Target platform | macOS 26.0 (Tahoe) or later, Apple silicon and Intel |
| Language / toolchain | Swift 6 (strict concurrency) |
| Companion documents | `Commands and Dictation.md`, the **normative** voice vocabulary |

---

## 0. Conventions

### 0.1 Requirement language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as
described in RFC 2119.

Requirements carry stable identifiers, `R-<AREA>-<n>` (e.g. `R-FSM-4`), used by the tests, the code
and [§15](#15-testing-and-acceptance-criteria). A removed requirement's identifier is retired, never
reused.

### 0.2 Document authority

Where this document and `Commands and Dictation.md` overlap:

- `Commands and Dictation.md` is authoritative for **which phrases exist and what they mean**.
- This document is authoritative for **how phrases are recognised, prioritised, dispatched, and
  what happens when they are not recognised**.

This document doesn't duplicate the vocabulary; [§8.5](#85-command-dispatch-contract) binds the two.
Where this document contradicts v1.0, this document wins ([§0.4](#04-resolved-conflicts) records why).

### 0.3 Normative references

| Ref | Version | Notes |
|---|---|---|
| Model Context Protocol specification | revision **2025-11-25** | The protocol revision the server implements and advertises. |
| `modelcontextprotocol/swift-sdk` | **0.12.1** (pinned, exact) | Provides `Server`, `StdioTransport`, `withMethodHandler(CallTool.self)`, `ProgressNotification`. 0.11.0 was the release that adopted spec revision 2025-11-25. |
| Apple `Speech` framework | macOS 26 | `SpeechAnalyzer`, `SpeechTranscriber`. |
| Apple `AVFoundation` | macOS 26 | `AVAudioEngine`, `AVSpeechSynthesizer`. |
| Apple `AppKit` / TextKit 2 | macOS 26 | `NSTextView`, `NSTextLayoutManager`, `NSTextStorage`. |
| RFC 2119 | — | Requirement keywords. |

### 0.4 Resolved conflicts

**C1 — Microphone state during playback.**
v1.0 states that voice control must be off while a response is being read, so that the synthesised
speech is not transcribed as a prompt. `Commands and Dictation.md` states that `Play` "locks voice
to Command Mode", and scopes the Text Editing family to "Both Panes when Not Speaking".

*Resolution:* **v1.0 wins.** The recogniser is torn down whenever audio plays (`R-TTS-4`); "locks
voice to Command Mode" means the mode it returns to afterwards (`R-TTS-5`). Playback can't be
interrupted by voice; `Stop` and `Got it!` work by mouse and keyboard ([§6.8](#68-keyboard-map)).

**C2 — "Slider".**
v1.0 calls for "a slider to enable/disable dictation mode" that also "switches between dictation
mode and command mode". A continuous slider is the wrong native control for a two-valued choice.

*Resolution:* a `Dictation | Command` segmented control plus a separate microphone toggle
([§6.3](#63-left-pane--talk)).

**C3 — `Add to vocabulary` binding.**
`Commands and Dictation.md` binds `Add to vocabulary` to
`SFVocabulary.shared().setCustomVocabularyStrings(…, for: .userContext)`. There is no `SFVocabulary`
type in the Speech framework; that call signature belongs to SiriKit's `INVocabulary`, and
`.userContext` is not a Speech framework concept.

*Resolution:* the behaviour is honoured — the selection is saved into a user vocabulary — through a
`VocabularyStore` applied as `AnalysisContext.contextualStrings` ([§8.6](#86-custom-vocabulary)).

**C4 — Formatting commands imply formatted text.**
`Bold that`, `Italicise that` and `Underline that` need formatted text, hence the attributed-text model
of [§7](#7-text-model).

---

## 1. Overview

### 1.1 What this is

VoiceChat lets a person hold a spoken, multi-turn conversation with the LLM driving their MCP host,
without typing. The host's model calls one MCP tool; a window appears; the person speaks; the model
answers; the answer is read aloud; the loop continues until the person ends it.

v1.0's one-line goal, *"Make sure that MCP server does not get out of sync with the UI"*, is the
primary correctness requirement; [§3](#3-vcp--daemon--mcp-server-control-protocol) and
[§5](#5-session-and-turn-state-machine) exist to satisfy it.

### 1.2 End-to-end flow

```
  MCP host (Claude Code / IDE / agent)
        │  spawns, stdio
        ▼
  voicechat-mcp ──── VCP over unix socket ────► VoiceChat.app (daemon)
        ▲                                              │
        │  tool result                                 │ creates
        │                                              ▼
        │                                   ┌──────────────────────┐
        │                                   │  Conversation window │
        │                                   │  TALK  │  LISTEN     │
        │                                   └──────────────────────┘
        │                                         │        │
        │                                    microphone  speaker
        │                                         │        │
        └───────────── the person ────────────────┴────────┘
```

1. The model calls `converse` with no arguments.
2. The daemon opens a conversation window; the left pane is focused and dictation is live.
3. The person speaks (or types) a prompt and says "Send prompt" or presses ⌘↩.
4. The tool call returns, carrying the prompt.
5. The model answers and calls `converse` again with its answer in `message`.
6. The answer appears in the right pane and is read aloud. The microphone is off while it reads.
7. When reading finishes, the loop returns to step 3 for the next turn.
8. The person clicks **End conversation** (or closes the window). The tool returns `ended`, and the
   model replies `Conversation ended.` and stops calling the tool.

### 1.3 Goals

| | |
|---|---|
| G1 | A person can complete an entire multi-turn conversation without touching the keyboard or mouse, except to interrupt playback. |
| G2 | The MCP server and the window can never disagree about whose turn it is. Disagreement is detected and reported, never papered over. |
| G3 | All speech processing is local. No audio and no transcript leaves the machine. |
| G4 | The window is a first-class macOS window — generous, resizable, accessible, not a port of a web layout — styled as a frameless, translucent, always-on-top pane of glass. |
| G5 | The app is fully usable by keyboard alone when speech is unavailable, denied, or unwanted. |
| G6 | Every voice command in `Commands and Dictation.md` is implemented and individually testable without a microphone. |

### 1.4 Non-goals

| | |
|---|---|
| N1 | VoiceChat talks to no LLM API: no API key, model selection, tokens or cost. The optional `model` field on `converse` ([§4.2](#42-the-converse-tool)) is only a display label. |
| N2 | VoiceChat does not manage conversation history, context windows, or memory. The host does that. |
| N3 | No wake word, no always-on listening outside an open conversation window. |
| N4 | No remote transport: stdio, and Streamable HTTP bound to `127.0.0.1` only ([§4.7](#47-streamable-http-transport)). |
| N5 | No iOS/iPadOS target. |
| N6 | Not a general dictation utility. It dictates into its own panes only. |

### 1.5 The two reference screenshots

Two screenshots of a web implementation (**Ref-A**, composing; **Ref-B**, speaking) inspired this
design; every behaviour taken from them is restated natively below, several deliberately changed
(e.g. `⌘↩` sends and `↩` inserts a newline, [§6.8](#68-keyboard-map)).

---

## 2. Architecture

### 2.1 Process topology

```
VoiceChat.app                          LSUIElement = 1 · ad-hoc signed
│                                      one instance per logged-in user
├── MenuBarController                  status item, session list, Streamable HTTP toggle
├── VCPListener                        AF_UNIX SOCK_STREAM listener
├── ConverseHTTPServer (optional)      Streamable HTTP MCP listener, 127.0.0.1 only, in-process
├── SessionRegistry (DaemonServer)     sessionID → Session, reached over VCP *or* in-process
│     └── Session                      state machine + window + speech I/O, one per MCP connection
│           ├── ConversationWindow     SwiftUI scene hosting two NSTextViews
│           ├── SpeechInputController  AVAudioEngine → SpeechAnalyzer
│           └── SpeechOutputController AVSpeechSynthesizer
└── Contents/MacOS/voicechat-mcp       stdio MCP server executable, shipped inside the bundle
                                       one process per MCP host connection, spawned by the host
```

Two transports reach the same `converse` tool and `SessionRegistry`: stdio (a `voicechat-mcp` process
per host, over VCP) and an in-process Streamable HTTP listener ([§4.7](#47-streamable-http-transport)).
Sessions opened either way are the same to the rest of the app (`R-APP-7`).

`R-ARCH-1` The daemon, the menu bar applet, and all conversation windows **MUST** be the same
process: microphone and speech-recognition permission (TCC) is granted to one signed app bundle, and
`NSStatusItem` and `NSWindow` need the same `NSApplication`. v1.0's "background daemon" and "menubar
applet" are two roles of that process.

`R-ARCH-2` The MCP server **MUST** ship inside the app bundle at
`Contents/MacOS/voicechat-mcp`, so that one install provides both halves and their versions cannot
drift. Host configuration points at that path
([§14.4](#144-registering-with-an-mcp-host)).

`R-ARCH-3` The MCP server **MUST** be able to start the daemon. On failing to connect, it resolves
the application in this order and launches it detached and without activating it (`open -g -j`):

1. `$VOICECHAT_APP_PATH`, if set.
2. `LSCopyApplicationURLsForBundleIdentifier("dev.sandipchitale.voicechat")`.
3. The bundle containing the running executable (`…/Contents/MacOS/` → up two levels).

It then polls for the socket every 100 ms for at most 10 s before failing the tool call with a
diagnostic that names the path it tried.

`R-ARCH-4` The daemon **MUST** tolerate many concurrent sessions from many hosts. Each session owns
exactly one window and one pair of speech controllers. Only one session may hold the microphone at a
time ([§8.7](#87-device-arbitration)).

### 2.2 Module layout

| Module | Kind | Contents | AppKit? |
|---|---|---|---|
| `VoiceChatKit` | library | Session state machine, VCP codec, Markdown ⇄ attributed conversion, command table and dispatcher, speech-text builder, vocabulary store, the transport-agnostic `converse`-tool engine (`ConverseSessionEngine`/`ConverseTool`, [§4.7](#47-streamable-http-transport)) | No — pure model layer, fully unit-testable. Depends on the headless `MCP` product only. |
| `VoiceChatUI` | library | SwiftUI views, `NSTextView` representables, window controller, menu bar, `DaemonServer`/`Session` (the session registry both transports share) | Yes |
| `VoiceChatMCPServer` | library | The Streamable HTTP transport: an in-process `ConverseSessionGateway` conformance plus the NIO-based HTTP listener | No AppKit directly, but depends on `VoiceChatUI` for `DaemonServer`/`Session` |
| `voicechat-mcp` | executable | stdio MCP server: VCP client, auto-launch, the VCP-specific `ConverseSessionGateway` conformance | No |
| `voicechatd` | executable | `NSApplicationDelegate`, wires `DaemonServer` (VCP) and, when enabled, `VoiceChatMCPServer` (HTTP) — *there is no separate Xcode app target*; [`Scripts/make-app.sh`](Scripts/make-app.sh) assembles the bundle directly from this SwiftPM executable ([§14.2](#142-layout)) | Yes |
| `vcp-probe` | executable (dev) | Drives a session over VCP with no MCP host, for testing | No |

`R-ARCH-5` `VoiceChatKit` **MUST NOT** import AppKit or SwiftUI. The command dispatcher operates on
an abstract `TextDocument` protocol (backed by `NSTextStorage` in production, by a plain in-memory
buffer in tests) so that every command in `Commands and Dictation.md` can be tested headlessly.

### 2.3 Filesystem layout

| Path | Purpose |
|---|---|
| `~/Library/Application Support/VoiceChat/` | Container, mode `0700` |
| `…/daemon.sock` | VCP rendezvous socket, mode `0600` |
| `…/vocabulary.json` | User vocabulary ([§8.6](#86-custom-vocabulary)) |
| `~/Library/Preferences/dev.sandipchitale.voicechat.plist` | Settings |
| `~/Library/Logs/VoiceChat/` | Rotating log files |

`R-ARCH-6` No transcript, prompt, or response is written to disk by default. Export is an explicit
user action ([§6.5](#65-history-strip)).

### 2.4 Sandboxing

`R-ARCH-7` VoiceChat is **not** App-Sandboxed: the socket must be reachable by a `voicechat-mcp`
spawned by any host, which a sandbox container can't offer (an XPC service would; deferred item
**B1**). Releases are ad-hoc signed; Developer ID signing and notarisation are deferred.

---

## 3. VCP — daemon ⇄ MCP server control protocol

### 3.1 Transport and framing

`R-VCP-1` VCP **MUST** use a `AF_UNIX` / `SOCK_STREAM` socket at
`~/Library/Application Support/VoiceChat/daemon.sock`.

`R-VCP-2` Messages **MUST** be JSON-RPC 2.0 objects, UTF-8 encoded, one per line, terminated by
`\n` (JSON Lines). Literal newlines inside strings are escaped as `\n` by JSON encoding, so the
framing is unambiguous. A line longer than 16 MiB **MUST** be rejected and the connection closed.

A socket (rather than XPC, deferred as **B1**) is inspectable with `nc`, needs no `launchd`
registration, and reuses the JSON-RPC codec the stdio server needs anyway.

### 3.2 Handshake and access control

`R-VCP-3` The first message on a connection **MUST** be `hello`. The daemon **MUST** close any
connection whose first message is anything else.

```jsonc
// →
{"jsonrpc":"2.0","id":1,"method":"hello","params":{
  "vcpVersion": 1,
  "client":  {"name":"voicechat-mcp","version":"0.0.2","pid":48213},
  "host":    {"name":"claude-code","version":"2.1.270"}   // from MCP initialize, may be null
}}
// ←
{"jsonrpc":"2.0","id":1,"result":{"vcpVersion":1,"daemonVersion":"0.0.2"}}
```

`R-VCP-4` Version negotiation is exact-match on `vcpVersion`. A mismatch **MUST** be answered with
error `vcp_version_unsupported`, listing the versions the daemon accepts, after which the daemon
closes the connection. The MCP server **MUST** surface this as a tool error naming both versions and
telling the user to relaunch VoiceChat — not as a silent failure.

`R-VCP-5` The socket **MUST** be created mode `0600` inside a mode `0700` directory, and the daemon
**MUST** additionally verify the peer's effective uid via `getsockopt(…, SOL_LOCAL, LOCAL_PEERCRED)`
and reject any connection whose uid differs from its own.

`R-VCP-6` A stale socket file (present but not accepting) **MUST** be unlinked and recreated at
daemon start. The daemon **MUST** hold an exclusive lock on a sibling `daemon.lock` file for its
lifetime so that a second instance refuses to start rather than stealing the socket.

### 3.3 Method catalogue

**Client → daemon (requests):**

| Method | Params | Result |
|---|---|---|
| `hello` | see above | `{vcpVersion, daemonVersion}` |
| `session.open` | `{sessionId, title?, host?, cwd?, model?}` | `{sessionId, turnId}` — the first turn id |
| `turn.await` | see [§3.4](#34-turnawait) | see [§3.4](#34-turnawait) |
| `turn.cancel` | `{sessionId, turnId}` | `{}` |
| `session.close` | `{sessionId, reason}` | `{}` |
| `session.roots` | `{sessionId, roots: [{uri, name?}]}` | `{}` — the host's MCP roots, sent after the session opens and again on `notifications/roots/list_changed` |
| `ping` | `{}` | `{}` |

**Daemon → client (notifications, no `id`):**

| Method | Params | Meaning |
|---|---|---|
| `session.ended` | `{sessionId, reason}` | The session is over. Any in-flight `turn.await` is resolved separately with `outcome:"ended"`. |
| `turn.progress` | `{sessionId, turnId, phase, detail?}` | Advisory. Drives MCP progress notifications ([§4.5](#45-long-wait-strategy)). `phase` ∈ `composing`, `dictating`, `speaking`, `idle`. |

### 3.4 `turn.await`

This single call carries the whole conversation loop.

```jsonc
// request — "here is my reply (or nothing, if this is the first turn); give me the next prompt"
{"jsonrpc":"2.0","id":7,"method":"turn.await","params":{
  "sessionId": "9E2C…",
  "turnId":    "t3",
  "assistant": {"markdown":"Why did the scarecrow win an award? …"},   // or null
  "waitMs":    240000,
  "model":     "claude-sonnet-5"    // optional, may change turn to turn
}}
```

Exactly one of the following is returned:

```jsonc
{"jsonrpc":"2.0","id":7,"result":{"outcome":"prompt","turnId":"t3","nextTurnId":"t4",
                                  "markdown":"tell me another one"}}

{"jsonrpc":"2.0","id":7,"result":{"outcome":"pending","turnId":"t3"}}

{"jsonrpc":"2.0","id":7,"result":{"outcome":"ended","reason":"user_ended"}}

{"jsonrpc":"2.0","id":7,"error":{"code":-32010,"message":"turn_out_of_sync",
  "data":{"currentTurnId":"t4","phase":"Composing"}}}
```

`reason` ∈ `user_ended` (the **End conversation** button), `window_closed`, `host_cancelled`,
`daemon_quit`, `mcp_exit`.

#### Synchronisation rules

`R-VCP-7` **`turnId` is the synchronisation token.** Every `turn.await` carries the turn the caller
believes is current. If it does not match the daemon's current turn, the daemon **MUST** answer
`turn_out_of_sync` carrying its own authoritative `currentTurnId` and `phase`. It **MUST NOT**
silently accept the call, and **MUST NOT** display the supplied `assistant` message. This is the
mechanism that satisfies goal **G2**.

`R-VCP-8` `turn.await` with a matching `turnId` and `assistant: null` is **idempotent**: it resumes
waiting for the same turn. This is what makes the `pending` → resume cycle in
[§4.5](#45-long-wait-strategy) safe to repeat indefinitely.

`R-VCP-9` `turn.await` with a non-null `assistant` for a turn that already has a response recorded
**MUST** fail with `turn_out_of_sync`. A response is written to a turn exactly once.

`R-VCP-10` At most one `turn.await` may be in flight per session. A second concurrent call **MUST**
fail with `turn_already_awaited`.

`R-VCP-11` `outcome:"pending"` is returned when `waitMs` elapses with the person still composing.
It carries no prompt and does not advance the turn.

`R-VCP-12` When the daemon returns `outcome:"prompt"`, it **MUST** atomically advance its own
current turn to `nextTurnId` before writing the response. The next `turn.await` from the client
therefore carries `nextTurnId`, and a client that replays an old `turnId` is caught by `R-VCP-7`.

### 3.5 Connection loss and shutdown

`R-VCP-13` Peer disconnect while a session is bound **MUST** terminate that session: the daemon
closes its window without a confirmation sheet and discards its state. A person's unsent text is
lost in this path; the daemon **SHOULD** log the discarded text at debug level.

`R-VCP-14` On daemon quit, every in-flight `turn.await` **MUST** be resolved with
`outcome:"ended", reason:"daemon_quit"` before the socket closes, so no client is left hanging.

`R-VCP-15` `session.close` from the client **MUST** close the window immediately, without a
confirmation sheet — the decision has already been made upstream.

### 3.6 Error codes

| Code | Symbol | Meaning |
|---|---|---|
| `-32010` | `turn_out_of_sync` | `turnId` mismatch. `data` carries the authoritative turn and phase. |
| `-32011` | `turn_already_awaited` | A `turn.await` is already in flight for this session. |
| `-32012` | `unknown_session` | No such `sessionId`. |
| `-32013` | `vcp_version_unsupported` | Handshake version mismatch. |
| `-32014` | `session_limit_reached` | The daemon declines to open another window. |
| `-32015` | `daemon_shutting_down` | The daemon is quitting; retry after relaunch. |

`R-VCP-16` Every VCP error surfaced to the model **MUST** be rendered as an actionable sentence, not
a code. A code alone teaches the model nothing about what to do next.

---

## 4. The MCP server

### 4.1 Identity and capabilities

`R-MCP-1` The server **MUST** identify as `voicechat`, version matching the app bundle's, and
declare protocol revision **2025-11-25**.

`R-MCP-2` The server **MUST** declare the `tools` capability only. It **MUST NOT** declare
`resources`, `prompts`, `sampling`, or `elicitation`.

Elicitation doesn't fit: the conversation is a long-lived window, not a one-shot form, and many hosts
don't support it. The tool-return loop of [§4.3](#43-the-conversation-loop) works on any host that
can call a tool.

`R-MCP-3` The server **MUST NOT** write anything to `stdout` except JSON-RPC frames. All logging
goes to `stderr` and to the log file ([§12.3](#123-logging)).

### 4.2 The `converse` tool

One tool covers starting a conversation and every turn, so there's only one sequence to get right.

```jsonc
{
  "name": "converse",
  "title": "Talk with the user by voice",
  "inputSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "message": {
        "type": "string",
        "description": "Your reply to the user, in Markdown. Omit this only on your very first call (which opens the conversation) and when resuming after a 'waiting' result."
      },
      "continuation": {
        "type": "string",
        "description": "Opaque token. Supply it, unchanged and alone, only when a previous result had status 'waiting'."
      },
      "model": {
        "type": "string",
        "description": "Optional. The name of the model driving this call (e.g. 'claude-sonnet-5'). Shown in the window; may change between calls."
      }
    }
  },
  "outputSchema": {
    "type": "object",
    "required": ["status"],
    "properties": {
      "status":       {"type":"string","enum":["prompt","waiting","ended"]},
      "user_message": {"type":"string"},
      "turn":         {"type":"integer"},
      "continuation": {"type":"string"},
      "reason":       {"type":"string"}
    }
  },
  "annotations": {
    "title": "Voice conversation",
    "readOnlyHint": false,
    "destructiveHint": false,
    "idempotentHint": false,
    "openWorldHint": true
  }
}
```

`R-MCP-4` Results **MUST** be returned as **both** `structuredContent` (validating against
`outputSchema`) and a human-readable `content[0].text` mirror, since many hosts show the model only
the text.

#### Tool description (normative text)

This description teaches the host's model the loop. It **MUST** ship as written (the shipped text also
covers debates, [§17](#17-debate)).

> Hold a spoken, multi-turn conversation with the user in a dedicated window on their Mac. The user
> speaks or types; you reply; your reply is read aloud to them; they answer. Use this when the user
> asks to talk, to use voice, or to have a back-and-forth conversation.
>
> **How to run the conversation:**
>
> 1. **Start** by calling `converse` with no arguments. A window opens on the user's screen.
> 2. Each call returns a `status`. Act on it:
>    - `status: "prompt"` — `user_message` is what the user just said. Answer it, then call
>      `converse` again with your answer in `message`. Your answer is displayed and read aloud.
>    - `status: "waiting"` — the user is still composing. Call `converse` again **immediately**,
>      passing back the `continuation` token unchanged and **no** `message`. Do not write anything
>      to the user, do not do other work, and do not stop. This result only means the window is
>      still open and the user has not finished speaking yet.
>    - `status: "ended"` — the user closed the conversation. Reply with exactly
>      `Conversation ended.` and do not call `converse` again.
> 3. Keep looping until you get `ended`. The conversation is over only when the user ends it.
>
> **Rules:**
>
> - Never invent, guess, or summarise a user turn. The only thing the user said is what arrives in
>   `user_message`.
> - Write `message` as if speaking it aloud, because it will be. Prefer short sentences. Markdown
>   formatting is rendered in the window; code blocks are shown but not read aloud.
> - Do not ask the user to type in the host's own chat while a conversation is open — they are
>   looking at the VoiceChat window.
> - If a call returns an error, report it to the user in plain language and stop; do not retry in a
>   loop.

`R-MCP-5` The description **MUST** state the `waiting` → immediate-recall rule: treating `waiting` as
an ending is the likeliest failure, and only the instruction prevents it.

### 4.3 The conversation loop

| Call | Args | Daemon action | Result |
|---|---|---|---|
| 1st | — | `session.open`, then `turn.await(t1, assistant: nil)` | `prompt` with the user's first prompt |
| nth | `message` | `turn.await(tn, assistant: message)` | `prompt` with the next prompt |
| resume | `continuation` | `turn.await(same turn, assistant: nil)` | `prompt`, `waiting`, or `ended` |
| after ended, with `message`/`continuation` | either | none — the old conversation is over | `ended`, repeating the same reason |
| after ended, with neither | — | discard the old connection and counters, then behave exactly as the 1st call | `prompt` with a **new** first prompt |

`R-MCP-6` The server holds `sessionId` and the current `turnId` in process memory for the lifetime
of the stdio process. `continuation` is an opaque, signed encoding of `(sessionId, turnId, nonce)`;
the server **MUST** reject a `continuation` that does not match its own current state rather than
trusting it.

`R-MCP-7` Calling `converse` with `message` **and** `continuation` together **MUST** fail with a
tool error explaining that only one is valid at a time.

`R-MCP-8` Calling `converse` with `message` when no session is open **MUST** open a session and
discard the message with a note in the result text (a reply to a prompt never given would
desynchronise the conversation).

`R-MCP-17` One stdio process may hold many conversations in turn. A bare `converse()` (no `message`,
no `continuation`) after a conversation ended **MUST** start a new one, discarding the old session
id, counters and ended flag, exactly as a first call. A call that still carries `message` or
`continuation` after ending is stale and **MUST** keep returning `ended`.

### 4.4 Result rendering

**`status: "prompt"`** — `content[0].text`:

```
The user said:

<user_message>
tell me another one
</user_message>

Answer this, then call `converse` again with your answer in `message` to continue.
```

`R-MCP-9` The user's words **MUST** be delimited by `<user_message>` … `</user_message>`, separating
them from the loop instructions, and any literal `</user_message>` in the transcript **MUST** be
neutralised first.

**`status: "waiting"`** — `content[0].text`:

```
The user is still composing their message. The conversation window is open and waiting.

Call `converse` again immediately with continuation="<token>" and no `message`.
Do not reply to the user and do not stop.
```

**`status: "ended"`** — `content[0].text`:

```
The conversation has ended (reason: user_ended).

Reply to the user with exactly: Conversation ended.
Do not call `converse` again.
```

`R-MCP-10` The `ended` text **MUST** instruct the exact reply, satisfying the v1.0 requirement that
the model "should only show 'Conversation ended'".

### 4.5 Long-wait strategy

A turn can take many minutes, but MCP clients time requests out (often after 60 s), and not every
client resets its timer on `notifications/progress`. So progress alone can't be relied on.

`R-MCP-11` The server **MUST** implement both layers:

- **Layer A — progress.** If `params._meta.progressToken` is present, emit `notifications/progress`
  every 5 s while waiting, with a `message` reflecting the `turn.progress` phase reported by the
  daemon ("Listening…", "User is composing…", "Speaking the response…"). `progress` increments
  monotonically; `total` is omitted, since the wait has no known length.
- **Layer B — bounded wait with continuation.** Regardless of Layer A, no single `converse` call
  waits longer than `VOICECHAT_TURN_WAIT_MS` (default **240 000**, minimum 10 000). When it
  elapses, the call **returns** `status:"waiting"` with a continuation token instead of continuing
  to block.

`R-MCP-12` Layer B **MUST NOT** be disabled by a progress token: correctness rests on B alone.

`R-MCP-13` The bounded wait **MUST NOT** advance the turn, display anything, or change the window in
any way. From the person's point of view a `waiting` cycle is invisible.

### 4.6 Cancellation and shutdown

`R-MCP-14` On `notifications/cancelled` for an in-flight `converse`, the server **MUST** send
`session.close(reason: "host_cancelled")` and stop. The window shows a terminal banner
([§6.9](#69-terminal-and-error-presentation)). Cancellation ends the session, not just the turn, since
a half-cancelled turn is exactly the desynchronised state to avoid.

`R-MCP-15` On `stdin` EOF, `SIGTERM`, or `SIGINT`, the server **MUST** send
`session.close(reason: "mcp_exit")` and exit within 2 s.

`R-MCP-16` If the daemon becomes unreachable mid-call, the tool **MUST** fail with a message naming
the socket path and suggesting relaunching VoiceChat. It **MUST NOT** retry silently.

### 4.7 Streamable HTTP transport

*Opt-in, off by default.* A second way to reach the **same** `converse` tool, for MCP clients that
speak HTTP rather than spawning a stdio process.

`R-MCP-18` The tool's schema, description and result rendering **MUST** be defined once
(`ConverseTool`, in `VoiceChatKit`) and used by both transports; `tools/list` is byte-identical on
both.

Both transports share `ConverseSessionEngine` (`VoiceChatKit`: turn and continuation bookkeeping, and
`R-MCP-17`), over a `ConverseSessionGateway` (`openSession`/`awaitTurn`/`closeSession`/
`discardSession`): `VCPSessionGateway` in `voicechat-mcp` (over VCP), and `InProcessSessionGateway` in
`VoiceChatMCPServer` (calling `DaemonServer`/`Session`/`TurnCoordinator` directly).

`R-MCP-19` The HTTP transport **MUST** reach a session in-process, never by connecting to VCP as a
client of itself.

The transport is the swift-sdk's own `StatefulHTTPServerTransport` (MCP 2025-03-26: one `/mcp`
endpoint; POST with SSE responses; GET for a standalone stream; `Mcp-Session-Id`; `DELETE` ends a
session), with a SwiftNIO listener, `HTTPApp`, adapted from the SDK's reference. A per-session
`onClose` hook (on `DELETE`, idle timeout or quit) calls `engine.shutdown(reason:)`, which closes that
conversation's window, as `R-APP-7` requires.

`R-MCP-20` One `Server`, `ConverseSessionEngine` and `InProcessSessionGateway` — so one window —
**MUST** exist per `Mcp-Session-Id`. There's no cap on sessions (a known gap).

**Binding and enablement (`R-APP-8`).** The listener **MUST** bind `127.0.0.1` only (hardcoded). It
starts at launch only when `VOICECHAT_MCP_HTTP_PORT` is set (which also picks the port); otherwise the
menu bar's checkable **"MCP Server (port …)"** item ([§10](#10-menu-bar-applet)) starts and stops it,
on port 8765 by default. A bind failure shows an alert when started from the menu, and is only logged
at automatic startup.

`R-SEC-8` Even with the SDK's Origin/Host validation (`OriginValidator.localhost()`), a loopback TCP
port is reachable by **any local user account**, weaker than VCP's `0600` socket (`R-SEC-3`). That's
accepted and is why the transport is opt-in; a shared-secret validator (`BearerTokenValidator`) is a
possible future addition.

**Known issue.** A bare `converse()` over HTTP has occasionally returned `status: "ended"` at once
without opening a window, even on a fresh `Mcp-Session-Id`. The cause is not identified.

---

## 5. Session and turn state machine

This state machine is the authority for every control, microphone transition and window change; UI
state **MUST** be derived from it, never set ad hoc.

### 5.1 States

| State | Meaning |
|---|---|
| `Idle` | Session object exists; no window shown. Transient, at open only. |
| `Composing` | Left pane active. Awaiting a prompt from the person. |
| `Submitted` | Prompt handed to the MCP server. Awaiting the model's reply. |
| `Responding.Auto` | Reply displayed; TTS playing; `Stop` has **not** been pressed this turn. |
| `Responding.Manual` | Reply displayed; `Stop` has been pressed at least once this turn. |
| `Ended` | Terminal. Window shows a closing banner, then closes. |

`R-FSM-1` `Responding.Auto` and `Responding.Manual` differ **only** in what happens when speech
finishes: once stopped, a response stays however often it is replayed.

`R-FSM-2` The manual latch **MUST** reset at every turn: each response starts in `Responding.Auto`.

### 5.2 Transition table

| # | From | Event | To | Recogniser | Voice mode | TTS | Turn |
|---|---|---|---|---|---|---|---|
| 1 | `Idle` | `session.open` | `Composing` | start | Dictation | — | 1 |
| 2 | `Composing` | Send (button, ⌘↩, or `Send prompt`) with non-empty text | `Submitted` | **stop** | — | — | — |
| 3 | `Composing` | Send with empty/whitespace text | `Composing` | unchanged | unchanged | — | — |
| 4 | `Composing` | mode toggle / `command mode` / `dictation mode` | `Composing` | unchanged | flips | — | — |
| 5 | `Composing` | mic toggle (⌃R) | `Composing` | starts/stops | unchanged | — | — |
| 6 | `Submitted` | response received | `Responding.Auto` | **stop** | — | **start** | — |
| 7 | `Submitted` | response is empty/whitespace | `Composing` | start | Dictation | — | +1 |
| 8 | `Responding.Auto` | TTS `didFinish` | `Composing` | start | Dictation | — | +1 |
| 9 | `Responding.Auto` | `Stop` (button, ⇧⌘P, or `Stop`) | `Responding.Manual` | start | **Command** | stop | — |
| 10 | `Responding.Manual` | `Play` (button, ⇧⌘P, or `Play`) | `Responding.Manual` | **stop** | — | **start** | — |
| 11 | `Responding.Manual` | TTS `didFinish` | `Responding.Manual` | start | **Command** | — | — |
| 12 | `Responding.Manual` | `Stop` | `Responding.Manual` | start | **Command** | stop | — |
| 13 | `Responding.*` | `Got it!` (button, ⌘↩, or `Got it`) | `Composing` | start | Dictation | stop | +1 |
| 14 | any non-terminal | **End conversation** / ⌘W / ⌘Q / ⌥⌘E | `Ended` | stop | — | stop | — |
| 15 | any non-terminal | `session.close` from peer | `Ended` | stop | — | stop | — |
| 16 | any non-terminal | VCP peer disconnect | `Ended` | stop | — | stop | — |

Rows 8, 11 and 13 implement v1.0's "switch to the next prompt when the TTS runs out", "the response
mode stays", and "in manual mode only 'Got it' finishes the response".

### 5.3 Invariants

| | Invariant |
|---|---|
| `R-FSM-3` | In `Submitted` and `Responding.Auto`, and while any utterance is being spoken in `Responding.Manual`, the recogniser is stopped and the audio input node has no tap installed. |
| `R-FSM-4` | The recogniser is running **iff** the state is `Composing` with the mic enabled, or `Responding.Manual` with nothing being spoken. |
| `R-FSM-5` | At most one `turn.await` is in flight per session. |
| `R-FSM-6` | In `Composing` the left pane is first responder; in `Responding.*` the right pane is first responder. |
| `R-FSM-7` | The turn counter increases only on rows 7, 8, and 13, and only by one. |
| `R-FSM-8` | `Ended` is terminal. No event moves out of it. Every event other than window-close is ignored. |
| `R-FSM-9` | Entering `Composing` for turn *n*+1 commits turn *n* (prompt and response) to the history strip and clears the prompt pane. The response pane keeps turn *n*'s response, dimmed and read-only, as context until the next response arrives. |
| `R-FSM-10` | Pane editability follows [§6.6](#66-control-enablement-matrix) by state alone; viewing a past turn (R-UI-11) does not add a further restriction to the **prompt** pane, but the **response** pane is additionally read-only whenever a past turn is displayed, since what was already said cannot be revised. |

### 5.4 Edge cases

| Situation | Required behaviour |
|---|---|
| Response arrives after the window was closed | Discarded; the in-flight `turn.await` has already resolved `ended`. No window is reopened. |
| Response is empty or whitespace only | Row 7: no TTS, no `Responding` state; straight to the next turn. |
| **Send** pressed in the same runloop turn as an incoming `session.ended` | `Ended` wins. The prompt is discarded and the person is shown the closing banner. |
| Person edits the response pane, then presses `Play` | Speech is rebuilt from the **current** pane contents ([§9.2](#92-deriving-spoken-text)). |
| TTS fails to start (no voice, audio device lost, Talking Head refuses) | Treated as `didFinish` (row 8 or 11), with a warning chip. A broken speaker never strands the conversation. |
| Microphone permission denied | The session runs fully; the mic toggle shows a denied state and the footer offers a System Settings link. Typing and all buttons work. |
| Second host opens a session while one is active | Allowed. A second window opens. Only the frontmost session may hold the microphone ([§8.7](#87-device-arbitration)). |
| `turn_out_of_sync` observed by the server | The tool call fails with a message telling the model the conversation state moved on and it should stop; the window is left untouched and usable. |

---

## 6. Conversation window

### 6.1 Window

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ✕  VOICECHAT — CLAUDE-CODE                       [ SONNET-5 · CLAUDE CODE ]         │  header
│    Composing · turn 3                                                        │  subtitle
├───────────────────────────────────┬──────────────────────────────────────────┤
│ TALK                    listening │ LISTEN                                   │
│ ┌───────────────────────────────┐ │ ┌──────────────────────────────────────┐ │
│ │                               │ │ │                                      │ │
│ │  tell me another one▌         │ │ │  Type here or wait for a response…   │ │
│ │                               │ │ │                                      │ │
│ │                               │ │ │                                      │ │
│ │          ⌘↩ Send · ⌃R Mic     │ │ │                                      │ │
│ ├───────────────────────────────┤ │ ├──────────────────────────────────────┤ │
│ │ ◉  [Dictation|Command]        │ │ │ ▁▃▅  Waiting…                        │ │
│ │    Listening…        [ Send ] │ │ │                   [▶ Play]  [Got it] │ │
│ └───────────────────────────────┘ │ └──────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────────────────────┤
│ ▸ History · turn 3 of 3                                                      │  collapsed
├──────────────────────────────────────────────────────────────────────────────┤
│                                                      [ End conversation ]    │  bottom bar
└──────────────────────────────────────────────────────────────────────────────┘
```

| Property | Value |
|---|---|
| Default content size | 1360 × 860 pt |
| Minimum content size | 1040 × 680 pt |
| Style | Borderless, resizable, translucent; always on top (`.floating`); draggable by its header; joins the active Space and may sit over full-screen apps |
| Frame autosave | `VoiceChatConversationWindow` |
| Title | `VoiceChat <version> — <project>` (the last path component of the host's working directory), or `VoiceChat <version>` when unknown. The host is not repeated here; it is in the identity badge. |
| Subtitle | Tracks state (below) |
| Identity badge | `<model> · <host>` (either alone if only one is known), shown in the header's trailing area. The model is optional and supplied by the caller on each `converse` call. The host is the MCP client's own name from its `initialize` request (`clientInfo.title` if sent, else a friendly name for known clients — `claude-code` → Claude Code, `claude-ai` → Claude Desktop — else `clientInfo.name` verbatim), so it never depends on the model. The bottom bar reads `Connected to <host> — <project> · <model>`. The badge is hidden when neither is known. |
| Background | `NSGlassEffectView` (regular style) under a wash (black in dark, white in light) whose strength the header slider sets; 24 pt corner radius; cyan hairline rim |

`R-UI-1` The header's subtitle line **MUST** track session state (`NSWindow.title` keeps the title for
Mission Control and accessibility):

| State | Subtitle |
|---|---|
| `Composing` | `Composing · turn 3` |
| `Composing`, mic live | `Listening · turn 3` |
| `Submitted` | `Waiting for the assistant…` |
| `Responding.Auto` | `Speaking · turn 3` |
| `Responding.Manual` | `Paused · turn 3` |
| `Ended` | `Conversation ended` |

`R-UI-2` The header carries:
- leading, a close button (a live session ends with `window_closed`);
- the identity badge (hidden when empty);
- trailing, a theme control — **Default** (follows the system), **Light**, **Dark** — (`VoiceChatTheme`,
  default `system`), and a transparency slider (0 see-through … 1 nearly solid, default 0.35) that scales
  only the window wash and editor-card fill (`VoiceChatGlassOpacity`). Both apply to every window.

It **MUST NOT** carry Send, Play, Stop or Got it!, which belong to their panes.

A layout button (⌥⌘L), beside the pin, arranges the panes side by side or stacked (prompt above
response); its icon shows the layout a click switches to. The divider between the panes sets their
proportion (double-click splits evenly), never shrinking a pane below 420 pt wide (side by side) or 180
pt tall (stacked). Layout and per-layout proportion are shared and persisted (`VoiceChatPaneLayout`,
default side by side; `VoiceChatSideBySideSplit`, `VoiceChatStackedSplit`, default 0.5).

`R-UI-3` The window **MUST** be resizable to the minimum size without clipping any control, without
horizontal scrolling of the layout, and without the footer bars wrapping. At minimum width each pane
is 420 pt wide; footer buttons collapse to icon-only with tooltips below 480 pt of pane width.

### 6.2 Pane anatomy

Both panes share one structure:

```
  TALK                                        ← header: 13 pt semibold, uppercase, +0.6 tracking,
                                                 secondaryLabelColor, trailing status chip
  ┌────────────────────────────────────────┐ ← editor card
  │                                        │    corner radius 12 pt, corner brackets
  │   text view, 16 pt inset               │    fill    black @ 28 % over the glass
  │                                        │    border  1 pt white @ 12 %
  │                                        │    focus   1.5 pt system-cyan ring, bright brackets
  │                    hint line, 11 pt    │            + 12 pt cyan glow @ 35 % opacity
  ├────────────────────────────────────────┤ ← hairline
  │  footer, 52 pt, controls               │
  └────────────────────────────────────────┘
```

`R-UI-4` The active pane **MUST** be indicated by the focus ring above; the inactive pane shows only
its 1 pt border.
Under **Increase Contrast** the ring thickens to 3 pt and the shadow is dropped.

`R-UI-5` Both panes **MUST** grow with the window. Neither may have a fixed height. The editor card
fills all vertical space not used by the header, footer, history strip, and bottom bar.

### 6.3 Left pane — TALK

Header status chip: `Idle`, `Listening`, `Command mode`, `Mic off`, `Mic unavailable`.

Footer, leading to trailing:

| Control | Detail |
|---|---|
| Mic toggle | 28 pt circle. Off: `mic.slash` on `quaternaryLabelColor`. On: `mic.fill`, white on `systemRed`, with a level ring driven by input RMS at 20 Hz. Denied: `mic.slash` with a warning tint; clicking opens System Settings. |
| Mode control | Two-position segmented control: `Dictation` / `Command`. **This is the "slider" of v1.0 (C2).** Disabled when the mic is off. |
| Status text | `Listening…`, `Command mode`, `Paused`, or the denial reason. `secondaryLabelColor`, 12 pt. |
| — | Flexible space |
| **Send** | `.borderedProminent`, default button, keyboard equivalent ⌘↩. Disabled when the pane is empty or the state is not `Composing`. |

Hint line above the footer, trailing-aligned, 11 pt `tertiaryLabelColor`:
`⌘↩ Send · ⌃R Mic · ⇧⌘D Mode`.

`R-UI-6` Volatile (interim) recognition results **MUST** render inline at the insertion point in
`tertiaryLabelColor`, and **MUST** be replaced in place — not appended — when the corresponding
finalised result arrives. Interim text is never part of the document and is discarded if recognition
stops.

`R-UI-7` Pressing **Send** with an empty or whitespace-only pane **MUST NOT** submit. The pane
performs a brief horizontal shake (suppressed under Reduce Motion) and, if the mic is live, the
status text reads `Nothing to send yet`.

### 6.4 Right pane — LISTEN

Header status chip: `Waiting`, `Speaking`, `Paused`, `Read`.

Placeholder when empty: `Waiting for the response…` while `Submitted`, otherwise `The response will
appear here.` The pane is editable only while `Responding`.

Footer, leading to trailing:

| Control | Detail |
|---|---|
| Level glyph | Five bars, animated only while speaking; static at 20 % opacity otherwise. Hidden under Reduce Motion, which shows a static `speaker.wave.2` instead. |
| Status text | `Waiting…`, `Speaking…`, `Paused`, `Finished reading`. |
| — | Flexible space |
| **Play / Stop** | One button with one shortcut (⇧⌘P), showing only the action that applies. While speaking it reads `■ Stop` (`systemRed`) and stops; otherwise it reads `▶ Play`, enabled only in `Responding.Manual`, and plays. |
| **Got it!** | `.borderedProminent`, default button while in `Responding.*`, keyboard equivalent ⌘↩. |

`R-UI-8` While speech is playing, the sentence currently being spoken **MUST** be highlighted in the
pane using a `selectedTextBackgroundColor`-derived tint at 35 % opacity, driven by
`speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` mapped through the segment table in
[§9.2](#92-deriving-spoken-text). The pane scrolls to keep the highlight visible. Highlighting is
suppressed while the person is editing the pane.

`R-UI-9` Code blocks **MUST** render with a distinct background, `SF Mono` at 13.5 pt, and a hover
**Copy** button. They are announced but not read ([§9.2](#92-deriving-spoken-text)).

### 6.5 History strip

`R-UI-10` A collapsible strip sits between the split view and the bottom bar. Collapsed by default,
toggled with ⇧⌘H or by clicking its disclosure header. Collapsed height 28 pt; expanded 160 pt.

Header: `▸ History · turn 3 of 3`, plus a trailing **Export…** button (⌘S).

Expanded content: a list of committed turns, one row each —
`3  tell me another one    →    I told my wife she was drawing…`, truncated per column.

| Behaviour | Requirement |
|---|---|
| `R-UI-11` | Selecting a past turn loads its prompt and response into the panes and shows a `Return to current turn` bar. The response pane is read-only while peeking; the prompt pane follows its normal rule ([§6.6](#66-control-enablement-matrix)), and dictation, the mic and the mode control are unaffected (R-UI-27). |
| `R-UI-12` | Returning restores the live turn exactly, including the unsent draft and cursor — unless the peeked prompt was sent (R-UI-27), which supersedes the draft. |
| `R-UI-13` | History covers the **current conversation only**. It is held in memory and discarded when the session ends. |
| `R-UI-14` | **Export…** writes a Markdown transcript to a user-chosen location via `NSSavePanel`. This is the only path by which conversation content reaches disk. |
| `R-UI-29` | When the MCP client supports `roots`, the server fetches them (`roots/list`, refreshed on `notifications/roots/list_changed`) and the bottom bar shows a folder chip with the count; its popover lists each root, revealable in the Finder. The fetch never delays a turn (abandoned after 5 s); no roots, no chip. |
| `R-UI-27` | A loaded past prompt can be edited and sent in `Composing` like any prompt, making a new turn. Only the response that was said is immutable. |

### 6.6 Control enablement matrix

`R-UI-15` Control state **MUST** be derived from this table.

| Control | `Composing` | `Submitted` | `Responding.Auto` | `Responding.Manual` (idle) | `Responding.Manual` (speaking) | `Ended` |
|---|---|---|---|---|---|---|
| Left text view | edit | read-only | read-only | read-only | read-only | read-only |
| Mic toggle | **on** | off, disabled | off, disabled | off, disabled | off, disabled | off, disabled |
| Mode control | enabled\* | disabled | disabled | enabled | disabled | disabled |
| **Send** | enabled† | disabled | disabled | disabled | disabled | disabled |
| Right text view | edit | edit | edit | edit | edit | read-only |
| **Play / Stop** button | Play, disabled | Play, disabled | **Stop** | **Play** | **Stop** | Play, disabled |
| **Got it!** | disabled | disabled | **enabled** | **enabled** | **enabled** | disabled |
| **End conversation** | enabled | enabled | enabled | enabled | enabled | disabled |
| History strip | enabled | enabled | enabled | enabled | enabled | enabled |

\* disabled when the mic is off or unavailable.  † disabled when the pane is empty.

### 6.7 Metrics, typography, and colour

| Token | Value |
|---|---|
| Outer padding | 20 pt |
| Gap between panes | 16 pt |
| Editor card radius | 12 pt |
| Editor text inset | 16 pt |
| Footer height | 52 pt |
| Bottom bar height | 56 pt |
| Body text | SF Pro 15 pt, line spacing 5 pt, paragraph spacing 10 pt |
| Code | SF Mono 13.5 pt |
| Pane header | SF Pro 13 pt semibold, uppercase, tracking +0.6 |
| Hint / caption | 11 pt |
| Control height | 28 pt (32 pt for prominent buttons) |

`R-UI-16` All colours **MUST** come from semantic `NSColor` values (`labelColor`,
`secondaryLabelColor`, `tertiaryLabelColor`, `systemCyan`, `systemRed`), from black/white at a stated
opacity, or from materials. No literal RGB values. The wash and line tones flip with the effective
appearance, and the highlight is `systemCyan` (deepened on light glass), not the accent colour.

`R-UI-17` Animations **MUST** honour `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
Under Reduce Motion the level ring, the level glyph, and the empty-send shake are replaced by static
equivalents.

### 6.8 Keyboard map

`R-UI-18` Every action reachable by voice or mouse **MUST** also be reachable by keyboard (goal G5).

| Key | Action | Context |
|---|---|---|
| ⌘↩ | **Send** | `Composing` |
| ⌘↩ | **Got it!** | `Responding.*` |
| ↩ | Insert newline | Either text view |
| ⌃R | Toggle microphone | Any non-terminal state |
| ⇧⌘D | Toggle Dictation / Command | Mic enabled |
| ⇧⌘P | **Stop** speech while speaking, otherwise **Play** | `Responding.*` |
| ⇧⌘H | Toggle history strip | Any |
| ⌘S | Export transcript | Any |
| ⌥⌘E | **End conversation** | Any non-terminal state |
| ⌘W | **Close** the window | `Ended` only — the app installs no `File`/`Window` menu, so ⌘W does not close a live window; use ⌥⌘E or the traffic light to end one |
| ⌘Q | **Close** the front window (a live conversation ends, as with its close button) | Any window — never quits; only the menu bar menu's **Quit VoiceChat** does (`R-APP-10`) |
| ⌘, | Settings | App-wide |

`R-UI-19` **End conversation** ends the session immediately, with no confirmation, whatever is unsent
or speaking.

### 6.9 Terminal and error presentation

`R-UI-20` On entering `Ended`, the window **MUST** show a non-modal banner across the top of the
split view naming the reason — `Conversation ended.`, `The assistant cancelled this conversation.`,
`VoiceChat lost contact with the assistant.` — dim both panes to read-only, and close automatically
after 4 s. **End conversation** becomes an always-enabled **Close** button. Auto-close is suppressed
while the history strip is expanded (so the transcript can be exported); **Close** always works
(`R-APP-7`).

`R-UI-21` Recoverable problems (mic denied, no voice installed, recogniser unavailable) **MUST**
appear as an inline row inside the affected pane's footer with a one-line explanation and a single
action button, never a modal alert.

### 6.10 Accessibility

| | |
|---|---|
| `R-UI-22` | Every control carries an accessibility label and, where its meaning is state-dependent, a value. The two text views are labelled `Prompt` and `Response`. |
| `R-UI-23` | State changes post `NSAccessibilityPriorityAnnouncement` announcements: "Listening", "Sending", "Speaking", "Response finished", "Conversation ended". |
| `R-UI-24` | While VoiceOver runs, automatic playback **MUST** default to off (the two voices would talk over each other); row 6 of [§5.2](#52-transition-table) then enters `Responding.Manual` directly. The person is told once, with a control to override. |
| `R-UI-25` | Full keyboard navigation between panes, footers, history, and the bottom bar via Tab / ⇧Tab, with a visible focus ring on every stop. |
| `R-UI-26` | All text honours the system text size where the platform supports it, and no control has a fixed height that would clip enlarged text. |

---

## 7. Text model

### 7.1 Rich text in both panes

`R-TXT-1` Both panes **MUST** be `NSTextView` instances using TextKit 2 (`NSTextLayoutManager`) over
an `NSTextStorage`, and **MUST** hold attributed text rather than plain strings. `Bold that`, `Italicise that`, and
`Underline that` (C4) operate on real attributes.

### 7.2 Inbound: Markdown → attributed

`R-TXT-2` A response arrives over VCP as Markdown. It **MUST** be converted with
`AttributedString(markdown:options:)` using `interpretedSyntax: .full` and preserving
`presentationIntent` / `inlinePresentationIntent`, then styled by a `MarkdownStyler` that maps
intents to concrete attributes:

| Intent | Rendering |
|---|---|
| `header(level:)` | SF Pro semibold, 20 / 17 / 15 pt for levels 1–3, 12 pt space above |
| `emphasized` / `stronglyEmphasized` | Italic / bold traits |
| `code` (inline) | SF Mono 13.5 pt on a 6 % `labelColor` background, 3 pt radius |
| `codeBlock(languageHint:)` | SF Mono 13.5 pt block, 6 % background, 12 pt padding, copy affordance |
| `unorderedList` / `orderedList` | Hanging indent 20 pt, marker in `secondaryLabelColor` |
| `blockQuote` | 3 pt leading rule in `separatorColor`, 16 pt indent |
| `link` | `linkColor`, underlined, URL in the `.link` attribute |
| `thematicBreak` | 1 pt `separatorColor` rule |

`R-TXT-3` The original Markdown **MUST** be kept alongside as `sourceMarkdown`, for export; it is
never re-derived from the attributed string.

`R-TXT-4` Malformed Markdown **MUST NOT** fail the turn. On a conversion error the raw text is
displayed verbatim as plain body text and a debug-level log entry is written.

### 7.3 Outbound: attributed → Markdown

`R-TXT-5` On **Send**, the prompt pane is serialised to Markdown by a `MarkdownSerializer`
supporting a deliberately small subset: bold, italic, underline (as `<u>`), inline code, and fenced
code blocks. Everything else is emitted as plain text.

`R-TXT-6` Text with no formatting **MUST** serialise byte-identically to what was typed or dictated.

`R-TXT-7` Markdown metacharacters the person typed (`*`, `_`, `` ` ``, `#` at line start) **MUST NOT**
be escaped: `2 * 3 * 4` means exactly that.

### 7.4 Right-pane edits

`R-TXT-8` Edits to the response pane are **local only**: they change what speech reads
([§9.2](#92-deriving-spoken-text)) and what is exported, and are **never** sent to the model.

`R-TXT-9` The history strip records the response **as received**, marked `(edited)` if it was edited.

---

## 8. Speech input

### 8.1 Engine

`R-STT-1` Recognition **MUST** use the macOS 26 `Speech` framework: `SpeechAnalyzer` driving a
`SpeechTranscriber` module, fed from an `AVAudioEngine` input tap.

```
AVAudioEngine.inputNode
  └── tap (bufferSize 4096) ──► AsyncStream<AnalyzerInput>
                                    └── SpeechAnalyzer
                                          └── SpeechTranscriber(
                                                locale: <setting>,
                                                reportingOptions: [.volatileResults],
                                                attributeOptions: [.audioTimeRange])
                                                └── AsyncSequence<Result>
                                                      ├── volatile  → interim UI text
                                                      └── finalized → commit or dispatch
```

`R-STT-2` Recognition **MUST** be on-device. No audio, and no derived transcript, may be sent off
the machine. Required model assets are ensured present at first use via the framework's asset
installation path; while a download is in progress the mic toggle shows `Preparing…` and is
disabled.

`R-STT-3` The engine **MUST** sit behind a `SpeechRecognitionEngine` protocol in `VoiceChatKit`,
with a `MockSpeechEngine` that emits scripted results, so the whole vocabulary is testable without a
microphone (goal G6).

`R-STT-4` Audio-route changes (headphones connected or removed, default device changed) **MUST** be
handled by tearing down and rebuilding the tap, preserving the current mode and any pending text.
The person sees at most a brief `Reconnecting…` in the status text.

### 8.2 Volatile and finalised results

| | |
|---|---|
| `R-STT-5` | Volatile results render as interim text per `R-UI-6`. They are never dispatched as commands and never enter the document. |
| `R-STT-6` | Only finalised results are acted on: inserted in Dictation Mode, or matched against the command table in Command Mode. |
| `R-STT-7` | If recognition stops with interim text outstanding, that text is discarded, not committed. |

### 8.3 Modes

Two modes, exactly as v1.0 describes:

| Mode | Finalised result behaviour |
|---|---|
| **Dictation** | Inserted at the insertion point, subject to the Dictation directives in `Commands and Dictation.md` (literal insertion with automatic punctuation, `<phrase> emoji`, `Type <phrase>`, `Insert date`, `Press Return key`, `Press Escape key`, `Add to vocabulary`). |
| **Command** | Matched against the command table. Matched → the operation runs. Unmatched → nothing is inserted (`R-STT-11`). |

| | |
|---|---|
| `R-STT-8` | A new turn starts in **Dictation** mode with the mic live, per v1.0 ("The prompt pane starts in dictation mode"). |
| `R-STT-9` | `command mode` and `dictation mode` **MUST** be recognised in *both* modes, **MUST** switch the mode, and **MUST NOT** be inserted as text in either. |
| `R-STT-10` | The mode control and ⇧⌘D perform exactly the same transition as the spoken phrases; there is one mode variable, not two. |

### 8.4 Mode indication

The mode shows in three places at once — the segmented control, the left header chip and the window
subtitle — because a command said in the wrong mode is typed as prose.

### 8.5 Command dispatch contract

`Commands and Dictation.md` lists the vocabulary; this section defines how it is applied.

**Normalisation.** A finalised transcript is normalised before matching:
lowercase; trim; collapse internal whitespace; strip trailing `.`, `,`, `!`, `?`; map spelled
cardinals to digits for `<count>`; normalise curly quotes and dashes to ASCII. The unnormalised
text is retained, because `<phrase>` operands must be matched against the document in their original
form.

**`<count>` grammar.** `R-STT-12` `<count>` accepts digits and the cardinal words *one* through
*twenty*, plus *a* and *an* as 1. An absent `<count>` means 1. A `<count>` larger than the available
extent clamps to the extent rather than failing.

**`<phrase>` resolution.** `R-STT-13` `<phrase>` is the greedy remainder of the utterance. It is
resolved against the pane text by case-insensitive, diacritic-insensitive search, choosing the
occurrence nearest the insertion point, searching forward first and then wrapping. If there is no
occurrence, the command is a no-op with feedback per `R-STT-11`. For `Replace <phrase> with
<phrase>`, the split is on the last occurrence of the word `with`.

**Precedence.** `R-STT-14` The command table is matched in this order, and the first match wins:

1. Mode switches (`command mode`, `dictation mode`)
2. System & Session Controls (`Send prompt`, `Stop`, `Play`, `Got it`). In Dictation Mode only
   `Send prompt` is recognised, and only as a whole utterance; the others would swallow ordinary words.
3. Text Selection
4. Text Navigation
5. Text Editing
6. Text Deletion

Within a group, longer literal patterns are matched before shorter ones, and all literal patterns
before parameterised ones — so `Select next word` never shadows `Select word`, and
`Delete previous 3 words` is not mistaken for `Delete previous`.

**Unmatched utterances.** `R-STT-11` In Command Mode an unmatched utterance **MUST NOT** be inserted
as text. The dispatcher shows a transient toast — `Unrecognised command: "…"` — for 2 s in the
affected pane and, if enabled, plays the system error sound.

**Undo.** `R-STT-15` Every document mutation, from both modes, **MUST** be registered with the text
view's `UndoManager` as a single coalescible action named after the command, so that `Undo that` and
`Redo that` work over voice edits exactly as ⌘Z does over typing.

**Session controls while a pane is not focused.** `R-STT-16` Session controls dispatch to the
session regardless of which pane holds focus. Editing, selection, navigation, and deletion commands
apply to the focused pane, which is determined by state per `R-FSM-6`.

**Availability.** `R-STT-17` A command that is unavailable in the current state — `Send prompt`
outside `Composing`, `Play` while already speaking — **MUST** be reported as
`Not available right now`, distinct from `Unrecognised command`.

**Coverage.** `R-STT-18` Every phrase in `Commands and Dictation.md` **MUST** have an implementation
and at least one test ([§15.2](#152-required-tests)).

*Resolutions of what `Commands and Dictation.md` leaves open* (confirmed by tests):

- **`line`** as a unit means the *logical* line (between `\n`s), not the wrapped line, which depends
  on window width and can't be tested headlessly.
- **`Select that`** alone may act with nothing selected, selecting the word nearest the caret. Every
  other `that` command needs a non-empty selection and reports `Nothing selected` otherwise.
- **`Capitalize` / `Italicize`** are accepted as synonyms of `Capitalise` / `Italicise`.
- **`Replace <phrase> with <phrase>`** splits on the last standalone `with`; `Insert <phrase>
  after/before <phrase>` likewise on the last `after`/`before`.

### 8.6 Custom vocabulary

`R-STT-19` `Add to vocabulary` **MUST** take the current selection (or, if the selection is empty,
the word under the insertion point), persist it into `VocabularyStore`
(`~/Library/Application Support/VoiceChat/vocabulary.json`), and apply the updated phrase list to the
active transcriber, taking effect on the next recogniser start at the latest.

`R-STT-20` The store is capped at 100 phrases, most-recently-added first, matching the platform
guidance for contextual phrase lists. Phrases are kept short — one or two words. The list is
editable in Settings ([§11](#11-settings)).

*Binding note (C3).* Instead of the non-existent `SFVocabulary` call named in `Commands and
Dictation.md`, the vocabulary **MUST** be applied as:

```swift
let context = AnalysisContext()
context.contextualStrings[.general] = phrases     // ≤ 100, short
try await analyzer.setContext(context)            // or pass via init(inputSequence:…)
```

`R-STT-21` *Retired* (a fallback for a transcriber without contextual phrases, which doesn't arise).

### 8.7 Device arbitration

`R-STT-22` At most one session may hold the microphone at a time. When a session starts recognition,
any other session holding it **MUST** be stopped, and that session's left pane footer **MUST** show
`Microphone taken by another conversation` with a control to reclaim it.

`R-STT-23` If another application seizes the input device, recognition stops and the mic toggle
returns to its off state with an explanatory status. The conversation remains fully usable.

### 8.8 Permissions

`R-STT-24` `Info.plist` **MUST** carry `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription`, both written in terms of what the person gets, not what the
app does.

`R-STT-25` Authorisation **MUST** be requested at first microphone activation, never at launch.

`R-STT-26` Denial **MUST NOT** degrade anything other than speech. The window, typing, all buttons,
and the full conversation loop keep working; the footer shows one line and an **Open System
Settings…** button that deep-links to the Privacy pane.

---

## 9. Speech output

### 9.1 Synthesis

`R-TTS-1` Playback **MUST** use `AVSpeechSynthesizer` with a locally installed voice. No network
voice, no third-party engine. The one exception is Talking Head, which the person opts into
(`R-TTS-16`).

`R-TTS-2` The response **MUST** be split into sentence-level utterances
(`String.enumerateSubstrings(in:options:[.bySentences, .localized])`) and enqueued in order, rather
than spoken as one utterance, for an immediate **Stop** and per-sentence highlighting.

`R-TTS-3` Voice, rate, pitch, and volume come from Settings. Personal Voice is offered when
`AVSpeechSynthesizer.requestPersonalVoiceAuthorization` grants access; otherwise the picker lists
the installed system voices, with a link to the voice download pane in System Settings.

### 9.2 Deriving spoken text

`R-TTS-6` Spoken text **MUST** be derived from the pane's **current attributed content**, not from
`sourceMarkdown`. A response the person has edited is read as edited.

Derivation rules:

| Content | Spoken as |
|---|---|
| Body text | Verbatim |
| Bold / italic / underline | Verbatim; attributes do not affect speech |
| Heading | The heading text, followed by a 0.4 s `postUtteranceDelay` |
| Inline code | The code text verbatim (setting: *Speak inline code*, default on) |
| Code block | `Code block, <n> lines.` and the block is **skipped** (setting: *Speak code blocks*, default off) |
| Link | The link text only; the URL is not read |
| List item | The item text, preceded by a 0.2 s pause; ordered lists prepend the number |
| Block quote | `Quote:` then the text |
| Thematic break | A 0.4 s pause |
| Table | `Table, <r> rows, <c> columns.` then each row read cell by cell |

`R-TTS-7` The builder **MUST** produce, alongside the utterances, a segment table mapping each
utterance index to the `NSRange` of the pane text it came from, so `willSpeakRangeOfSpeechString`
can be translated into a document range for highlighting (`R-UI-8`). Skipped content gets a segment
with no utterance, so the highlight never drifts.

`R-TTS-8` A response longer than 20 000 characters is truncated for speech at the last sentence
boundary before the limit, and a final utterance says `Response truncated for reading.` The full
text remains visible in the pane.

### 9.3 Microphone interlock

`R-TTS-4` The recogniser **MUST** be stopped and the input tap removed **before** the first
utterance is enqueued, and **MUST NOT** be restarted until `didFinish` or `didCancel` (C1), so the
reply is never transcribed as the next prompt.

`R-TTS-5` On `didFinish` or `didCancel` the recogniser restarts in:

- **Command** mode, if the state is `Responding.Manual`;
- **Dictation** mode, if the state has advanced to `Composing`.

`R-TTS-9` The interlock **MUST** be implemented as a single owner of the audio session — a
`AudioRouteCoordinator` through which both controllers acquire and release the device — so a missed
callback or a second `Play` while stopping can't leave the tap installed.

### 9.4 Auto and manual modes

| | |
|---|---|
| `R-TTS-10` | A response begins playing automatically on arrival (`Responding.Auto`), except when `R-UI-24` applies. |
| `R-TTS-11` | Finishing naturally in `Responding.Auto` advances to the next turn. |
| `R-TTS-12` | **Stop** latches the turn into `Responding.Manual` permanently. |
| `R-TTS-13` | In `Responding.Manual`, **Play** and **Stop** may be used any number of times, and finishing naturally does **not** advance the turn. |
| `R-TTS-14` | **Got it!** is the only way out of `Responding.Manual`. |

`R-TTS-15` **Play** in `Responding.Manual` starts from the beginning of the response, unless there
is a non-empty selection, in which case it reads the selection only. There is no resuming midway.

### 9.5 Talking Head

`R-TTS-16` When Talking Head's `th` is installed (found in `~/.local/bin`, `/usr/local/bin`,
`/opt/homebrew/bin` or `/Applications/TalkingHead.app`, and resolving into `TalkingHead.app`), the
response footer **MUST** offer a toggle, next to Mute, that reads replies through Talking Head instead
of `AVSpeechSynthesizer`, with a male/female picker (default male). Both are shared by every window
and remembered, and apply from the next reading.

- The text read is the spoken text of §9.2 (or the selection, `R-TTS-15`).
- In a debate each seat has its own character: the first takes the picker's choice, the other the
  opposite, and choosing in one seat sets the other to the opposite. The debate's `DebateCoordinator`
  holds the choice, never the shared setting.
- The reply pane shows no sentence highlight (Talking Head reports no progress); Talking Head's own
  speech bubble highlights each word.
- Mute means silence: while muted Talking Head isn't used, and muting mid-reading ends it as a finish.
- Closing the window or quitting ends a reading.

`R-TTS-19` **How a reading is sent.** When Talking Head's spooler socket answers
(`~/Library/Application Support/TalkingHead/speech.sock`, or `TALKINGHEAD_SPOOLER_SOCKET`; owned by the
same user), the reading goes there as `{"type":"speak","text","voice","alwaysOnTop":true}` on its own
connection, through `VoiceChatKit.TalkingHeadSpooler` (self-contained; no code shared with Talking
Head). With no socket, or no reply within 300 ms, it falls back to `th --always-on-top -v <voice>` with
the text on standard input; the process's exit is the reading's natural finish, and **Stop**
terminates it. (A late spooler reply finds its connection closed, so Talking Head drops that copy.)

`R-TTS-20` **Spooler events:** `finished` → the natural finish (what `R-TTS-11` and `R-TTS-13` act
on); `stopped` not asked for by VoiceChat (Talking Head's own Stop, an agent's) → the natural finish;
`error` → the natural finish plus the warning chip with its message; the connection ending without a
result (Talking Head quit) → the natural finish. VoiceChat's **Stop** closes the connection, which
takes the speech back, as a cancellation.

`R-TTS-17` **Presence.** While Talking Head is on and not muted, its face **MUST** follow the §5 state
machine between readings, as a `presence` message on the spooler socket. Presence is derived only
from the machine, after every transition (`ConversationModel.onMachineChanged`), and on changes to
mute, the toggle and the character; only changes are sent.

| State (§5.1) | Presence |
|---|---|
| `Idle`, `Ended` | none |
| `Composing` | listening |
| `Submitted` | thinking |
| `Responding.Auto` | none (the reading is the face) |
| `Responding.Manual`, speaking / not speaking | none / listening |
| Talking Head off, or muted | none |

`R-TTS-18` Each finalised dictation phrase while `Composing` **MUST** send a one-shot nod
(`"pulse":"nod"`), at most once per 600 ms. Interim results never nod.

`R-TTS-21` Each window holds one presence connection, opened at the first presence other than none,
kept (sending `none`) through the responding states, and closed when the conversation ends, Talking
Head is turned off or muted, or the window closes, which lets the face go. If presence isn't
acknowledged within 300 ms (an older Talking Head answers `error`), the window sends no more presence
and readings work as before. Each debate seat holds its own, with its own character. The microphone
interlock (§9.3) is unchanged.

---

## 10. Menu bar applet

`R-APP-1` The app **MUST** run as `LSUIElement` with no Dock icon and no main menu-bar application
menu, presenting a single `NSStatusItem`.

Icon: `waveform.circle`, switching to `waveform.circle.fill` while any session is open, with a
subtle pulse while any session is speaking (suppressed under Reduce Motion).

The menu:

```
  VoiceChat 0.0.13
  ─────────────────────────────────
  Idle  /  2 conversations open
      claude-code — project — turn 3
      WebStorm — turn 1
  ─────────────────────────────────
  New Debate…                     ⌥⌘D
      owl-42 — 1 of 2 seats filled  ▸  Copy join instruction for "against" · End Debate
  ─────────────────────────────────
  Test Conversation…              ⌥⌘T
  ─────────────────────────────────
  ✓ MCP Server (port 8765)
  MCP Server Config…
  ─────────────────────────────────
  Quit VoiceChat                  ⌘Q
```

Designed but not built: permission rows, Settings…, Show Log and Start at Login (they depend on
[§11](#11-settings) and [§12.3](#123-logging)).

| | |
|---|---|
| `R-APP-2` | Selecting a session in the list focuses its window. |
| `R-APP-3` | **Test Conversation…** opens a window on a loopback session with no MCP host, echoing prompts back as responses. It **MUST** ship in release builds: it's how a person checks the microphone, voice and commands without a host. |
| `R-APP-4` | *Not implemented:* permission rows and **Permissions…**. |
| `R-APP-5` | *Not implemented:* **Start at Login**. The app starts manually or by the MCP server's auto-launch (`R-ARCH-3`). |
| `R-APP-6` | **Quit** first ends every session (each `turn.await` resolves `ended`), so no host is left hanging. It is immediate; there is no confirmation. |
| `R-APP-7` | A session leaves this list, and its window and model are freed, only when its window actually closes, not when the conversation ends. An ended window keeps its banner and **Close** button until dismissed, and still counts as open. |
| `R-APP-8` | **MCP Server (port …)** toggles [§4.7](#47-streamable-http-transport)'s listener live. It starts checked only when `VOICECHAT_MCP_HTTP_PORT` was set at launch; otherwise the default port is 8765. Turning it off fully releases the port and its tasks. |
| `R-APP-9` | **MCP Server Config…** opens one floating dialog (reopening brings it forward) with sample configuration for both transports — stdio at `/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp`, HTTP at `http://127.0.0.1:<port>/mcp` — as a JSON tab (`mcpServers`) and a Shell tab of remove-then-add commands for Claude Code, Antigravity and Codex, each with a copy button. **Copy** / **Copy All** and **Save…** (`NSSavePanel`) act on the tab. |
| `R-APP-10` | ⌘Q never quits the daemon. With one of its windows in front, it closes that window, the same as the window's own close button; a live conversation closed this way ends (§5.2 row 14). Only **Quit VoiceChat** in the menu bar menu quits, so conversations started later still find the daemon running. |

---

## 11. Settings

*Status: not built.* The design below is the target. Today the vocabulary persists without an editor
(`R-STT-19`), ending never asks for confirmation (`R-UI-19`), and the only speech-output settings
are Mute, Talking Head and a debate's voices.

| Pane | Contents |
|---|---|
| **General** | Start at Login. Confirm before ending a conversation (Always / Only with unsent work / Never; default: middle). Play a sound on unrecognised commands. |
| **Speech Input** | Recognition locale. Input device. Start dictation automatically on each new turn (default on). Custom vocabulary editor — add, remove, reorder, backing `Add to vocabulary` ([§8.6](#86-custom-vocabulary)). |
| **Speech Output** | Voice (including Personal Voice when authorised). Rate, pitch, volume, with a **Preview** button. Speak inline code (default on). Speak code blocks (default off). Automatically read responses (default on; forced off under VoiceOver per `R-UI-24`). |
| **Advanced** | Turn wait milliseconds (`VOICECHAT_TURN_WAIT_MS` override). Socket path (read-only, with **Reveal in Finder**). Log level. **Reset all settings**. |

`R-SET-1` Every setting **MUST** take effect without restarting the app. Changing the voice or rate
mid-conversation applies from the next utterance.

`R-SET-2` Settings are per-user in `~/Library/Preferences/dev.sandipchitale.voicechat.plist`. No
setting is per-session or per-host.

---

## 12. Errors, permissions, and diagnostics

### 12.1 Error presentation principles

| | |
|---|---|
| `R-ERR-1` | A conversation that can still function **MUST NOT** be interrupted by a modal alert. Recoverable problems appear inline per `R-UI-21`. |
| `R-ERR-2` | Every user-visible error states what happened, what still works, and the one action worth taking. |
| `R-ERR-3` | Errors surfaced to the *model* through a tool result **MUST** be plain sentences with an explicit instruction to stop rather than retry, so a failure cannot become a retry loop. |

### 12.2 Error catalogue

| Condition | Person sees | Model sees |
|---|---|---|
| Daemon not running and cannot be launched | — (no window) | `VoiceChat could not be started. The application was not found at <path>. Tell the user to install or launch VoiceChat, then stop.` |
| VCP version mismatch | — | `VoiceChat is version X but this MCP server expects Y. Tell the user to reinstall VoiceChat, then stop.` |
| Microphone denied | Footer row + **Open System Settings…** | nothing — the conversation is unaffected |
| Speech recognition denied | Footer row; mic toggle disabled | nothing |
| Recognition model still downloading | `Preparing speech…`, mic disabled | nothing |
| No speech voice installed | Right footer row + **Install voices…** | nothing; responses display normally |
| Audio device lost mid-playback | `Playback stopped — audio device changed` | nothing |
| Turn out of sync | — | `The conversation has moved on. Stop calling converse and tell the user what happened.` |
| Daemon quit mid-conversation | Terminal banner | `ended`, reason `daemon_quit` |

### 12.3 Logging

*Status: much simpler than designed.* `voicechat-mcp` writes one-line diagnostics to `stderr` only
(never `stdout`); the app logs nothing. The table is the target.

| | |
|---|---|
| `R-LOG-1` | *Not implemented.* `os.Logger`, subsystem `dev.sandipchitale.voicechat`, categories `vcp`, `mcp`, `session`, `stt`, `tts`, `ui`. |
| `R-LOG-2` | *Partial:* the MCP server logs to `stderr`, not to `~/Library/Logs/VoiceChat/mcp-<pid>.log`, and **never** to `stdout` (`R-MCP-3`). |
| `R-LOG-3` | Prompt and response text is never logged (today only statuses and errors are). |
| `R-LOG-4` | *Not implemented.* No **Show Log** item, no log directory, no rotation. |
| `R-LOG-5` | *Not implemented.* State transitions are not logged; a desync today can only be diagnosed by reproducing it live. |

---

## 13. Security and privacy

| | |
|---|---|
| `R-SEC-1` | Audio is captured, transcribed and synthesised on-device. VoiceChat makes no network connections (the only sockets are local: VCP, the loopback HTTP transport, and Talking Head's spooler). |
| `R-SEC-2` | No prompt, response, or transcript is written to disk unless the person explicitly exports one (`R-UI-14`). |
| `R-SEC-3` | The socket is mode `0600` inside a mode `0700` directory, and the peer uid is verified (`R-VCP-5`). Any process running as the same user can open a conversation window — the same trust boundary as the MCP host. |
| `R-SEC-4` | `continuation` tokens are authenticated against server-side state (`R-MCP-6`) and are meaningless to any other process. |
| `R-SEC-5` | Spoken content reaching the model is delimited (`R-MCP-9`). VoiceChat does not otherwise filter or moderate what the person says. |
| `R-SEC-6` | The `com.apple.security.device.audio-input` entitlement is in place. Hardened runtime, Developer ID signing and notarisation are not (P6); builds are ad-hoc signed, so permission grants may not survive an update. |
| `R-SEC-7` | *Not implemented* — depends on the Settings scene ([§11](#11-settings)), which does not exist yet. |

---

## 14. Build, packaging, installation

### 14.1 Prerequisites

`R-BLD-1` The Xcode licence must be accepted before anything builds:

```bash
sudo xcodebuild -license
```

(A one-time step on a new machine.)

### 14.2 Layout

```
VoiceChat/
├── Package.swift                 VoiceChatKit, VoiceChatUI, voicechatd, voicechat-mcp, vcp-probe, tests
├── Sources/
│   ├── VoiceChatKit/              headless: state machine, VCP, command grammar (R-ARCH-5)
│   ├── VoiceChatUI/                AppKit/SwiftUI/TextKit 2 window layer
│   ├── voicechatd/                 the daemon's `main.swift` (menu bar, VCP listener)
│   ├── voicechat-mcp/               the stdio MCP server's `main.swift`
│   └── vcp-probe/                  the no-host test harness
├── Tests/VoiceChatKitTests/
├── Tests/VoiceChatUITests/
├── App/                           Info.plist + entitlements — no Xcode project
├── Scripts/make-app.sh            assembles and signs .build/VoiceChat.app from SwiftPM output
├── Spec.md
├── README.md, SETUP.md
└── Commands and Dictation.md
```

`R-BLD-2` There is no Xcode project. [`Scripts/make-app.sh`](Scripts/make-app.sh) assembles
`VoiceChat.app` from the SwiftPM executables — `App/Info.plist`, `voicechatd` as
`Contents/MacOS/VoiceChat`, and `voicechat-mcp` — and ad-hoc signs the inner tool and the bundle with
its entitlements. `Scripts/release.sh <version>` builds the universal release zip after checking the
version in `App/Info.plist` and `VoiceChatVersion.swift`.

`R-BLD-3` `Scripts/make-app.sh` **MUST** copy the same build's `voicechat-mcp` into
`VoiceChat.app/Contents/MacOS/`, so the app and server can't drift apart.

### 14.3 Settings that matter

| Key | Value |
|---|---|
| Bundle identifier | `dev.sandipchitale.voicechat` |
| `LSUIElement` | `true` |
| `LSMinimumSystemVersion` | `26.0` |
| `NSMicrophoneUsageDescription` | *"VoiceChat listens so you can speak your prompts instead of typing them."* |
| `NSSpeechRecognitionUsageDescription` | *"VoiceChat turns your speech into text on this Mac so you can dictate and use voice commands."* |
| Swift language mode | 6, strict concurrency |

### 14.4 Registering with an MCP host

```bash
claude mcp add voicechat -- /Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp
```

or, for any host taking a config file:

```json
{
  "mcpServers": {
    "voicechat": {
      "command": "/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp"
    }
  }
}
```

`R-BLD-4` The server **MUST** require no arguments, no environment, and no prior daemon launch —
`R-ARCH-3` handles starting the daemon. Optional environment overrides, all implemented:
`VOICECHAT_APP_PATH` (bundle location, `DaemonLauncher`), `VOICECHAT_SOCKET` (`VCP.defaultSocketURL`),
`VOICECHAT_TURN_WAIT_MS` (bounded-wait duration, at least 10 s). There is no log level.

A host that speaks Streamable HTTP ([§4.7](#47-streamable-http-transport)) can use it alongside, or
instead of, stdio:

```json
{
  "mcpServers": {
    "voicechat-stdio": {
      "type": "stdio",
      "command": "/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp"
    },
    "voicechat-http": {
      "type": "streamable-http",
      "url": "http://localhost:8765/mcp"
    }
  }
}
```

`voicechat-http` connects only once **MCP Server (port …)** is on, or `VOICECHAT_MCP_HTTP_PORT` was
set at launch (`R-APP-8`); nothing launches the app for it.

---

## 15. Testing and acceptance criteria

### 15.1 Strategy

`VoiceChatKit` holds the state machine, codecs, command dispatcher, Markdown conversion, speech-text
builder and Talking Head client, and imports no UI framework (`R-ARCH-5`), so nearly every requirement
is testable with `swift test`, with no window and no microphone.

### 15.2 Required tests

| Area | Tests |
|---|---|
| State machine | Table-driven over every (state × event) pair, including pairs with no transition. Asserts the resulting state **and** every effect column of [§5.2](#52-transition-table). Every invariant in [§5.3](#53-invariants) asserted after each step of randomised event walks. |
| Edge cases | One test per row of [§5.4](#54-edge-cases). |
| VCP codec | Round-trip of every method and result shape; malformed line handling; over-length line rejection; `turn_out_of_sync` on replayed and skipped `turnId`; `turn.await` idempotence (`R-VCP-8`); concurrent-await rejection (`R-VCP-10`). |
| MCP server | Scripted stdio harness driving `initialize` → `tools/list` → `tools/call`, asserting all three result shapes, the `structuredContent`/text mirror pair, `<user_message>` delimiting and escaping, `message`+`continuation` rejection, forged-continuation rejection, and progress emission when a token is supplied. |
| Long wait | `waitMs` forced to 200 ms; assert a `waiting` result, assert the resume cycle repeats cleanly ≥50 times, and assert the window state is untouched throughout (`R-MCP-13`). |
| Command dispatcher | **At least one test per phrase in `Commands and Dictation.md`** (`R-STT-18`), run against an in-memory `TextDocument`. Plus: precedence ordering (`R-STT-14`), `<count>` parsing and clamping, `<phrase>` nearest-match and wrap-around, unmatched-utterance non-insertion (`R-STT-11`), mode switches never inserted (`R-STT-9`), undo grouping (`R-STT-15`), availability vs unrecognised distinction (`R-STT-17`). |
| Markdown | Round-trip fixtures; unformatted text byte-identity (`R-TXT-6`); malformed-input fallback (`R-TXT-4`); metacharacter non-escaping (`R-TXT-7`). |
| Speech text builder | Code-block announcement and skipping; heading pauses; link URL suppression; segment-table alignment across skipped content (`R-TTS-7`); truncation (`R-TTS-8`). |
| Interlock | With mock engines, assert `R-FSM-3` and `R-FSM-4` hold after every transition, including re-entrant Play/Stop sequences (`R-TTS-9`). |
| Talking Head | Every row of the presence table (`R-TTS-17`); change-only sequences over full turns and Stop → Play → Got it; the 600 ms nod throttle (`R-TTS-18`); against a fake spooler socket: each event mapping and Stop (`R-TTS-20`), fallback to a fake `th` with no socket or no reply (`R-TTS-19`), and the presence connection's lifetime and unsupported fallback (`R-TTS-21`). |

### 15.3 Integration

| | |
|---|---|
| `R-TST-1` | `vcp-probe` drives a full conversation over VCP with no MCP host, for exercising the window and speech paths in isolation. |
| `R-TST-2` | The stdio harness of [§15.2](#152-required-tests) runs in CI against a headless daemon build. |
| `R-TST-3` | The server is verified against `@modelcontextprotocol/inspector` for schema conformance before each release. |

### 15.4 Manual acceptance checklist

Each item names the requirements it verifies.

1. With no daemon running, a host calls `converse`; VoiceChat launches and a window appears. `R-ARCH-3`
2. The window opens at ≥1360×860, resizes to 1040×680 with nothing clipped, and looks correct in light and dark. `R-UI-3`, `R-UI-16`
3. Speaking a sentence fills the left pane; interim text appears grey and is replaced cleanly. `R-UI-6`, `R-STT-5`
4. Saying "command mode" switches mode without typing the words; saying "dictation mode" switches back. `R-STT-9`
5. In command mode, "select all" then "delete that" then "undo that" restores the text. `R-STT-15`
6. In command mode, an invented phrase types nothing and shows the unrecognised toast. `R-STT-11`
7. Saying "send prompt" submits; the mic stops; the subtitle reads `Waiting for the assistant…`. `R-FSM-3`
8. The response appears formatted (bold, lists, code block) and begins reading; the mic stays off. `R-TXT-2`, `R-TTS-4`
9. The spoken sentence is highlighted and the pane scrolls to follow it. `R-UI-8`
10. Code blocks are announced and not read. `R-TTS-6`
11. Letting it finish advances to a new turn with dictation live. `R-FSM` row 8
12. On the next turn, pressing **Stop** part-way keeps the response on screen; **Play** and **Stop** work repeatedly; finishing does not advance. `R-TTS-12`, `R-TTS-13`
13. In that paused state, saying "Got it" advances to the next turn. `R-TTS-14`, `R-STT-16`
14. Editing the response and pressing **Play** reads the edited text. `R-TTS-6`
15. Expanding history shows all turns; selecting one loads its response read-only and its prompt editable (while `Composing`); editing and sending it starts a new turn; returning without sending restores the draft. `R-UI-11`, `R-UI-12`, `R-UI-27`
16. Leaving the window untouched for longer than `waitMs` changes nothing on screen, and the conversation continues normally afterwards. `R-MCP-13`
17. **End conversation** ends it; the model replies exactly `Conversation ended.` `R-MCP-10`
18. Closing the window has the same effect. `R-FSM` row 14
19. Killing the MCP host closes the window. `R-VCP-13`
20. Denying microphone access leaves the whole conversation usable by keyboard. `R-STT-26`, G5
21. With VoiceOver on, responses do not auto-play and state changes are announced. `R-UI-24`, `R-UI-23`
22. **Test Conversation…** runs a full loop with no host configured. `R-APP-3`
23. Turning on **MCP Server (port …)** lets a `streamable-http` client at `http://localhost:<port>/mcp`
    `initialize`, list an identical `converse`, hold a conversation, and `DELETE` its session, closing
    the window. `R-MCP-18`–`R-MCP-20`, `R-APP-8` (see the known issue in [§4.7](#47-streamable-http-transport)).
24. With Talking Head on and its app running, the face listens (nodding per dictated phrase) while
    composing, thinks after Send, speaks the reply, and returns to listening without closing; Stop,
    Play and Got it keep it listening; Mute and ending let it go; each debate seat shows its own;
    quitting Talking Head mid-conversation falls back to `th` without stranding a turn. `R-TTS-17`–`R-TTS-21`

---

## 16. Implementation phases

| Phase | Deliverable | Status |
|---|---|---|
| **P0 — Skeleton** | `LSUIElement` app, status item, empty window. | ✅ |
| **P1 — The loop, typed** | VCP, `session.open` / `turn.await`, `converse`, the state machine, both panes, bounded wait. | ✅ |
| **P2 — Output** | Markdown rendering, speech, highlighting, Play / Stop / Got it!, the manual latch. | ✅ |
| **P3 — Dictation** | `SpeechAnalyzer`, permissions, the interlock, device arbitration. | ✅ |
| **P4 — Command mode** | The full command table with tests for every phrase (`R-STT-18`). | ✅ |
| **P5 — Fit and finish** | History, export, menu bar, Test Conversation, settings, accessibility, error catalogue. | 🟡 Settings ([§11](#11-settings)) not built; accessibility and error catalogue unverified |
| **P6 — Ship** | Developer ID signing, hardened runtime, notarisation. | ⬜ Ad-hoc signed releases only |
| **P7 — Streamable HTTP** | The opt-in second transport ([§4.7](#47-streamable-http-transport)). | ✅ with a known issue |
| **P8 — Debates** | Two clients argue a motion ([§17](#17-debate)). | ✅ |
| **P9 — Talking Head** | Replies read by Talking Head, and its face following the conversation ([§9.5](#95-talking-head)). | ✅ |

---

## 17. Debate

A debate is the ordinary conversation loop with the person's half automated: two MCP clients argue a
motion, and each one's finished statement becomes the other's incoming prompt. The person creates the
room and moderates it.

`R-DEB-1` The relay **MUST** hang off the turn advancing (`SessionEffects.advancesTurn`, rows 7, 8
and 13 of [§5.2](#52-transition-table)), never off speech finishing, which may never happen (no
auto-play, or Stop then **Got it!**).

`R-DEB-2` Muting **MUST NOT** change a debate: the reading, highlight and turn advance run on, so a
muted moderator follows by the highlight at the same pace. No relay may depend on audio state, an
audio tap, or an estimated reading time.

`R-DEB-3` There is **no speech arbiter**: stopping a seat's speech from outside its state machine
would strand it in `Responding.Auto`. A debate alternates by construction.

`R-DEB-4` The person creates a room from the menu bar; clients only join. Nothing opens until a seat
is taken.

`R-DEB-5` A client takes a seat by passing `debate_id` and `side` on its **first** `converse` call.
A refusal — unknown room, unknown seat, seat taken — **MUST** be an actionable sentence naming the
free seat or telling the model to ask the person, never a code.

`R-DEB-6` Handover is manual: a statement is placed in the other seat's prompt pane and **MUST NOT**
be sent for the person. Anything the person adds or changes before sending is attributed with a
`> Moderator:` line, and each seat's briefing tells it to comply with such lines.

`R-DEB-7` The first seat opens. Each briefing requires a debater to name itself in the first sentence
of every statement, so a listener always knows who is speaking. Both seats use the Mac's standard
voice unless the person chooses otherwise, separated by a small pitch and rate difference (with Talking
Head, by opposite faces, `R-TTS-16`).

`R-DEB-8` Each seat's window carries a debate bar showing the motion, the seat, the statement count,
what it is waiting for, and the moderator's **Skip turn** and **End debate**. Ending one seat ends
the other exactly once, and a finished room's id stops working immediately.

`R-DEB-10` Each seat's bar carries an **Auto** switch, off by default and per seat: while it is on,
a statement arriving in that window is passed to its debater without waiting for Send, and switching
it on passes along a statement already waiting. One side may run automatically while the other is
still moderated by hand. The debate machine holds the per-seat setting and applies it in its
`deliver` effect.

`R-DEB-9` Debate windows open with the microphone off — their turns arrive as text — and are placed
beside one another, stacking top and bottom where the screen is too narrow for two windows at
`Metrics.minWindowSize` (2 × 1040 pt plus a gap). Only the first seat's window takes focus.

## Appendix A — Glossary

| Term | Meaning |
|---|---|
| **Daemon** | The `VoiceChat.app` process: menu bar applet, VCP listener, and window host. One per user. |
| **Session** | One conversation, one window, one MCP server connection. |
| **Turn** | One prompt and its response. Identified by `turnId`; the synchronisation unit. |
| **VCP** | VoiceChat Control Protocol — the JSON-RPC link between the MCP server and the daemon ([§3](#3-vcp--daemon--mcp-server-control-protocol)). |
| **Host** | The application running the model and spawning the MCP server (Claude Code, an IDE, an agent). |
| **Volatile result** | An interim, revisable recognition hypothesis. |
| **Finalised result** | A committed recognition result; the only kind acted upon. |
| **Manual latch** | The per-turn flag set by **Stop** that moves a turn from `Responding.Auto` to `Responding.Manual`. |
| **Continuation** | The opaque token that resumes a bounded wait ([§4.5](#45-long-wait-strategy)). |

---

## Appendix B — Deferred and open items

| | Item | Notes |
|---|---|---|
| **B1** | App Sandbox via XPC Mach service | Would replace the Unix socket. Larger change; revisit if distribution through the Mac App Store is ever wanted. |
| **B2** | Persisted transcripts across sessions | Deliberately excluded (`R-UI-13`, `R-SEC-2`). Would need a storage format, a retention policy, and a privacy review. |
| **B3** | `SFSpeechRecognizer` fallback for macOS < 26 | The `SpeechRecognitionEngine` protocol (`R-STT-3`) already makes room for it. |
| **B4** | Multi-session polish | Multiple concurrent windows work; a session switcher and per-session audio routing are not designed. |
| **B5** | ~~Contextual-phrase API~~ | Resolved: `AnalysisContext.contextualStrings` ([§8.6](#86-custom-vocabulary)). |
| **B6** | Streaming responses | The model's reply arrives whole. Token-by-token display and speech would need a `turn.append` VCP method and re-segmentation mid-playback. |
| **B7** | Barge-in | Excluded by decision (**C1**); would need acoustic echo cancellation. |
| **B8** | Localisation | UI strings are `String(localized:)` from the start; only `en` ships. Command matching is English-only and tied to `Commands and Dictation.md`. |

---

## Appendix C — Original specification (v1.0)

The original request, verbatim. [Appendix D](#appendix-d--traceability-to-v10) traces every statement
to a requirement.

```markdown
# SPEC.md: macOS Voice-Enabled Dual-Pane UI for Model Context Protocol (MCP)

## Project Overview & Agent Objective

Build a native macOS app suite that provides a dual-pane, voice-enabled graphical user interface for LLM interactions through the Model Context Protocol (MCP) using the `stdio` transport based MCP server.

- A backgroun daemon manages sessions
- A menubar applet controls the damemon
- A STDIO Transport based MCP server that controls  a single multi-turn conversation with the user. It crates a session with the daemon. The daemon creates a dual pane window to display the conversation. 
- The dual pane window has a left pane for the prompt and a right pane for the response.
- Both panes are editable text boxes.

## Left Pane (prompt comoposition pane)
- There is a slider to enable/disable dictation mode which basically uses native macOS speech recognition to convert speech to text. 
- When in dictation mode, the user can speak commands or dictation
- The prompt pane starts in dictation mode of the voice control. 
- In dictation mode the user can say 'command mode' to switch to command mode.
- In command mode the user can say 'dictation mode' to switch to dictation mode.
- Refere to file `Commands and Dictation.md` for the commands and dictation support.
- The user can also use the slider to switch between dictation mode and command mode.
- The user can say "Send prompt" to end prompt composition. The composed prompt is then sent to the LLM via MCP server for processing. The LLM processes the prompt, creates the response, the response is captured by the STDIO MCP server which sents it to the pormpt pane via the daemon.

## Right Pane (response pane)

The response pane is a text view that displays the response from the LLM. The response pane is also editable and the user can edit the response. When the response is received and shown in right pane, it is read using native, local MacOS TTS engine. The use can click on 'Got it!' button to indicate that they are done with the response and the prompt pane can be activated for the next prompt composition. If the TTS runs out of text to read, then switch to next prompt composition turn. The user can click on a 'Stop' button to terminate the TTS playback. The user can also click on the 'Play' button to restart the TTS playback. Once the user has clicked on the 'Stop' Pane, this is a manual mode. The user can use 'Play', 'Stop', 'Play', 'Stop' as many times they want. In manual mode only 'Got it' finishes the response and switches to next prompt composition turn. Even if the full response is read, the response mode stays. Which response mode it actively reading the prompt, the voice control should be turned off, otherwise the spoken response is captured and and is taken as a prompt.  


### End conversatino button

There is a 'End conversation' button. This button should end the current conversation cycle and session ends. The LLM should only show 'Conversation ended'. Closing the conversation window has the same effect and the session ends.

### MCP Tool

Make sure the MCP server has a tool which can be invoked that starts the conversation. The tool description should educate the LLM how to create a multi-turn conversation. The control goes back to the Host/Agent/IDE's native prompt/response mechanism.

### UI/UX

- Make sure that MCP server does not get out of sync with the UI. 
```

---

## Appendix D — Traceability to v1.0

Every statement of [Appendix C](#appendix-c--original-specification-v10) maps to a requirement.

| v1.0 line | Statement | Realised by |
|---|---|---|
| 5 | Native macOS app suite, dual-pane, voice-enabled, stdio MCP | [§1](#1-overview), [§2.1](#21-process-topology) |
| 7 | Background daemon manages sessions | `R-ARCH-1`, `R-ARCH-4`, [§2.1](#21-process-topology) |
| 8 | Menubar applet controls the daemon | `R-ARCH-1`, [§10](#10-menu-bar-applet) |
| 9 | stdio MCP server, one multi-turn conversation, creates a session, daemon creates the window | `R-ARCH-2`, `R-MCP-1`, `R-VCP-3`, [§4.3](#43-the-conversation-loop) |
| 10 | Left pane prompt, right pane response | [§6.3](#63-left-pane--talk), [§6.4](#64-right-pane--listen) |
| 11 | Both panes editable | `R-TXT-1`, `R-FSM-10`, `R-TXT-8` |
| 14 | Slider enables/disables dictation; native speech recognition | Conflict **C2**, [§6.3](#63-left-pane--talk), `R-STT-1` |
| 15 | In dictation mode the user may speak commands or dictation | [§8.3](#83-modes), `R-STT-9` |
| 16 | The prompt pane starts in dictation mode | `R-STT-8`, row 1 of [§5.2](#52-transition-table) |
| 17 | "command mode" switches to command mode | `R-STT-9`, `R-STT-14` |
| 18 | "dictation mode" switches to dictation mode | `R-STT-9`, `R-STT-14` |
| 19 | Refer to `Commands and Dictation.md` | [§0.2](#02-document-authority), [§8.5](#85-command-dispatch-contract), `R-STT-18` |
| 20 | The slider also switches between modes | `R-STT-10`, conflict **C2** |
| 21 | "Send prompt" ends composition; prompt goes to the LLM; response returns via the daemon | Row 2 of [§5.2](#52-transition-table), `R-STT-14`, [§4.3](#43-the-conversation-loop) |
| 25 | Response pane displays the response | [§6.4](#64-right-pane--listen), `R-TXT-2` |
| 25 | Response pane is editable | `R-TXT-8`, `R-FSM-10` |
| 25 | Response is read by the native local TTS engine | `R-TTS-1`, `R-TTS-10` |
| 25 | "Got it!" finishes the response and activates the prompt pane | Row 13 of [§5.2](#52-transition-table), `R-TTS-14` |
| 25 | TTS running out of text advances to the next turn | Row 8, `R-TTS-11` |
| 25 | "Stop" terminates playback | Row 9, `R-TTS-12` |
| 25 | "Play" restarts playback | Row 10, `R-TTS-15` |
| 25 | After Stop, this is manual mode | `R-FSM-1`, `R-TTS-12` |
| 25 | Play/Stop usable any number of times | `R-TTS-13` |
| 25 | In manual mode only "Got it" finishes the response | Row 13, `R-TTS-14` |
| 25 | Even if fully read, response mode stays | Row 11, `R-TTS-13` |
| 25 | Voice control off while reading, so speech is not captured as a prompt | `R-TTS-4`, `R-FSM-3`, conflict **C1** |
| 30 | "End conversation" ends the cycle and the session | Row 14, `R-UI-19` |
| 30 | The LLM should only show "Conversation ended" | `R-MCP-10`, [§4.4](#44-result-rendering) |
| 30 | Closing the window has the same effect | Row 14, `R-UI-19` |
| 34 | A tool starts the conversation | [§4.2](#42-the-converse-tool) |
| 34 | The description educates the LLM on multi-turn conversation | `R-MCP-5`, the normative description text in [§4.2](#42-the-converse-tool) |
| 34 | Control returns to the host's native prompt/response mechanism | `R-MCP-10`, `R-MCP-14`, `R-MCP-15` |
| 38 | The MCP server must not get out of sync with the UI | `R-VCP-7`–`R-VCP-12`, [§5](#5-session-and-turn-state-machine), goal **G2** |
