# SPEC.md — VoiceChat

**A voice-driven, dual-pane, native macOS front end for multi-turn LLM conversations over the Model Context Protocol.**

| | |
|---|---|
| Document version | 2.2 — adds the Streamable HTTP MCP transport ([§4.7](#47-streamable-http-transport)), beyond the original P0–P6 phase plan |
| Status | Implemented through **P4** (core loop, speech I/O, dictation, full command mode); **P5** partial (history, export, menu bar, Test Conversation done; Settings not built); **P6** not started (ad-hoc signed only). A second MCP transport (Streamable HTTP, [§4.7](#47-streamable-http-transport)) is implemented and opt-in, but has a known, unresolved bug — see that section before relying on it. |
| Supersedes | v1.0 (the original 38-line sketch, preserved verbatim in [Appendix C](#appendix-c--original-specification-v10)) |
| Target platform | macOS 26.0 (Tahoe) or later, Apple silicon and Intel |
| Language / toolchain | Swift 6 (strict concurrency), Xcode 27 |
| Companion documents | `Commands and Dictation.md` — **normative** voice vocabulary. Not modified by this spec. |

---

## 0. Conventions

### 0.1 Requirement language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as
described in RFC 2119.

Normative requirements carry stable identifiers of the form `R-<AREA>-<n>` (e.g. `R-FSM-4`). These
identifiers are referenced by the acceptance checklist in [§15](#15-testing-and-acceptance-criteria)
and by the traceability table in [Appendix D](#appendix-d--traceability-to-v10). Identifiers are
stable across revisions of this document: when a requirement is removed, its identifier is retired,
not reused.

### 0.2 Document authority

Where this document and `Commands and Dictation.md` overlap:

- `Commands and Dictation.md` is authoritative for **which phrases exist and what they mean**.
- This document is authoritative for **how phrases are recognised, prioritised, dispatched, and
  what happens when they are not recognised**.

This document MUST NOT duplicate the vocabulary. [§8.5](#85-command-dispatch-contract) defines the
contract that binds the two.

Three points of tension between v1.0 and `Commands and Dictation.md` are resolved explicitly in
[§0.4](#04-resolved-conflicts). Where this document contradicts v1.0, this document wins; the
reasoning is recorded so it can be overturned deliberately rather than by accident.

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

*Resolution:* **v1.0 wins on the microphone.** The recogniser is fully torn down whenever audio is
playing (`R-TTS-4`). `Commands and Dictation.md` is satisfied by reading "locks voice to Command
Mode" as *the mode the recogniser returns to when playback stops or finishes* — which is precisely
what `R-TTS-5` specifies — and by reading "when Not Speaking" literally, since editing commands are
unreachable while muted. No hands-free interruption of playback is possible; `Stop` and `Got it!`
are reachable by mouse and keyboard during playback ([§6.8](#68-keyboard-map)).

**C2 — "Slider".**
v1.0 calls for "a slider to enable/disable dictation mode" that also "switches between dictation
mode and command mode". A continuous slider is the wrong native control for a two-valued choice.

*Resolution:* the control is a two-position segmented control labelled `Dictation | Command`,
accompanied by a separate microphone on/off toggle ([§6.3](#63-left-pane--talk)). Together these
provide both behaviours v1.0 asks of the "slider".

**C3 — `Add to vocabulary` binding.**
`Commands and Dictation.md` binds `Add to vocabulary` to
`SFVocabulary.shared().setCustomVocabularyStrings(…, for: .userContext)`. There is no `SFVocabulary`
type in the Speech framework; that call signature belongs to SiriKit's `INVocabulary`, and
`.userContext` is not a Speech framework concept.

*Resolution:* the command's **behaviour** is honoured exactly as written — the selected word or
phrase is persisted into a user vocabulary. The **binding** is specified in
[§8.6](#86-custom-vocabulary) against a `VocabularyStore` that is applied to the active transcriber.
`Commands and Dictation.md` is not edited. The replacement API was confirmed against the macOS 26
SDK during implementation — `AnalysisContext.contextualStrings` — so the behaviour the command
describes is fully available under a different call.

**C4 — Formatting commands imply formatted text.**
`Commands and Dictation.md` includes `Bold that`, `Italicise that`, and `Underline that`. These are
meaningless over a plain-text buffer. This is the direct justification for the attributed-text model
in [§7](#7-text-model).

---

## 1. Overview

### 1.1 What this is

VoiceChat lets a person hold a spoken, multi-turn conversation with whatever LLM is driving their
MCP host — Claude Code, an IDE, an agent — without typing and without looking at the host's own
chat surface. The host's model calls a single MCP tool; a window appears; the person speaks; the
model answers; the answer is read aloud; the loop continues until the person ends it.

The design goal that drives most of the decisions below is stated in v1.0 in one line — *"Make sure
that MCP server does not get out of sync with the UI"* — and it is treated here as the primary
correctness requirement, not a nicety. [§3](#3-vcp--daemon--mcp-server-control-protocol) and
[§5](#5-session-and-turn-state-machine) exist almost entirely to satisfy it.

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
| N1 | VoiceChat does not talk to any LLM API. It has no API key, no model selection, and no notion of tokens or cost. The host's model is the only model. The optional `model` field on `converse` ([§4.2](#42-the-converse-tool)) is a passive display label the caller supplies — VoiceChat never chooses, calls, or validates a model from it. |
| N2 | VoiceChat does not manage conversation history, context windows, or memory. The host does that. |
| N3 | No wake word, no always-on listening outside an open conversation window. |
| N4 | No remote transport. `stdio` only. |
| N5 | No iOS/iPadOS target. |
| N6 | Not a general dictation utility. It dictates into its own panes only. |

### 1.5 The two reference screenshots

Two screenshots of a web-based implementation informed this design and are referenced below as
**Ref-A** (left pane active, composing) and **Ref-B** (right pane active, speaking). They are
**inspiration only**. Every behaviour they suggest is restated here in native terms, and several
are deliberately changed:

| Ref behaviour | This spec |
|---|---|
| Purple outer glow on the active pane | 2 pt `controlAccentColor` focus ring plus a soft accent shadow ([§6.2](#62-pane-anatomy)) |
| `Enter` sends, `Shift+Enter` newline | `⌘↩` sends, `↩` inserts a newline ([§6.8](#68-keyboard-map)) — a multi-line composition pane must not lose text to a stray Return |
| Window title flips "Type or dictate" → "Speak" | `NSWindow.subtitle` tracks session state ([§6.1](#61-window)) |
| Buttons grey out per state | Normative, specified as a matrix ([§6.6](#66-control-enablement-matrix)) |
| Single turn visible, no history | Collapsible history strip for the current conversation ([§6.5](#65-history-strip)) |
| Fixed, cramped proportions | Explicit minimum sizes and padding scale ([§6.7](#67-metrics-typography-and-colour)) |

---

## 2. Architecture

### 2.1 Process topology

```
VoiceChat.app                          LSUIElement = 1 · ad-hoc signed (P6 not started)
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

Two independent transports reach the same `converse` tool and the same `SessionRegistry`: the
original stdio path (a separate `voicechat-mcp` process per host, talking over VCP) and an in-process
**Streamable HTTP** listener ([§4.7](#47-streamable-http-transport)) for MCP clients — web-based
agents among them — that speak HTTP rather than spawning a child process. A session opened either
way is indistinguishable to the rest of the app: it is a `Session` in the registry, shown in the menu
bar, subject to the same true-disposal rule (`R-APP-7`).

`R-ARCH-1` The daemon, the menu bar applet, and all conversation windows **MUST** be the same
process. This is not a simplification of convenience; it is forced:

- Microphone and speech-recognition authorisation (TCC) is granted to a **signed application
  bundle**. A headless `launchd` daemon without a bundle cannot reliably hold those grants, and
  splitting the applet from the window host would require two separate TCC identities for the same
  user-visible feature.
- `NSStatusItem` and `NSWindow` must be created by the same `NSApplication` instance.

The v1.0 description of "a background daemon" and "a menubar applet" is therefore realised as two
*roles* of one process. The applet is the daemon's control surface.

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

`R-ARCH-7` VoiceChat v1 is **not** App-Sandboxed. It is signed with a Developer ID certificate,
runs under the hardened runtime, and is notarised.

Rationale: the rendezvous socket must be reachable by an unsandboxed `voicechat-mcp` process spawned
by an arbitrary host with an arbitrary working directory and environment. A sandboxed app's
container path is not a viable rendezvous point across that boundary. Sandboxing would require
replacing the socket with an XPC Mach service registered by `launchd`, which is a coherent design
but a larger one. Recorded as deferred item **B1**.

---

## 3. VCP — daemon ⇄ MCP server control protocol

### 3.1 Transport and framing

`R-VCP-1` VCP **MUST** use a `AF_UNIX` / `SOCK_STREAM` socket at
`~/Library/Application Support/VoiceChat/daemon.sock`.

`R-VCP-2` Messages **MUST** be JSON-RPC 2.0 objects, UTF-8 encoded, one per line, terminated by
`\n` (JSON Lines). Literal newlines inside strings are escaped as `\n` by JSON encoding, so the
framing is unambiguous. A line longer than 16 MiB **MUST** be rejected and the connection closed.

*Why a socket and not XPC:* it is inspectable with `nc`, requires no `launchd` registration to
test, works when the daemon is launched from Xcode under a debugger, lets the MCP server reuse the
same JSON-RPC codec it already needs for stdio, and keeps the daemon launchable as a plain
application. The XPC alternative is recorded as **B1**.

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

*On not using elicitation:* MCP's `elicitation/create` is the idiomatic way for a server to ask a
human a question, and it is the right tool when the answer is a short structured value rendered by
the host's own UI. It is the wrong tool here for three reasons: the conversation surface is a
long-lived window the server owns rather than a one-shot form; elicitation requires the *client* to
declare the capability, which many hosts do not; and the flow here is a symmetric two-way
conversation, not a request for a field. The tool-return loop in [§4.3](#43-the-conversation-loop)
works on every host that can call a tool at all.

`R-MCP-3` The server **MUST NOT** write anything to `stdout` except JSON-RPC frames. All logging
goes to `stderr` and to the log file ([§12.3](#123-logging)). A single stray `print` corrupts the
protocol stream and is the single most common way a stdio MCP server fails.

### 4.2 The `converse` tool

One tool covers starting a conversation and every subsequent turn. A second tool would create a
second way for the model to get the sequence wrong.

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
`outputSchema`) and a human-readable `content[0].text` mirror. Many hosts surface only the text
block to the model; a structured-only result would be invisible to them.

#### Tool description (normative text)

This description is the contract that teaches the host's model how to run the loop. It is
reproduced here verbatim and **MUST** ship unchanged apart from version numbers.

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

`R-MCP-5` The description **MUST** state the `waiting` → immediate-recall rule. A model that treats
`waiting` as an ending is the most likely failure mode of this design, and it is prevented by
instruction, not by protocol.

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
discard the message with a note in the result text — the model has skipped step 1, and silently
displaying a reply to a prompt that was never given would desynchronise the conversation.

`R-MCP-17` The stdio process is not one-conversation-per-process (`R-MCP-6` already commits to
holding state "for the lifetime of the stdio process", and a host is free to reuse the same
connection for many conversations in one session). A bare `converse()` call — no `message`, no
`continuation` — arriving after a conversation has ended **MUST** be treated as the start of a new
one: the server discards the old session id, turn counters, and ended flag, and proceeds exactly as
on the very first call, opening a new session and a new window. A call that still carries `message`
or `continuation` after ending is unambiguously stale (the model missed the `ended` result) and
**MUST** keep returning `ended`, never silently reattaching stale content to a new conversation.

### 4.4 Result rendering

**`status: "prompt"`** — `content[0].text`:

```
The user said:

<user_message>
tell me another one
</user_message>

Answer this, then call `converse` again with your answer in `message` to continue.
```

`R-MCP-9` The user's words **MUST** be delimited by `<user_message>` … `</user_message>`. This is
prompt-injection hygiene: it keeps arbitrary spoken content lexically separated from the loop
instructions that surround it. The server **MUST** neutralise any literal `</user_message>` occurring
in the transcript before wrapping.

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

A turn can legitimately take many minutes: a person may think, be interrupted, or compose a long
prompt by voice. MCP clients apply request timeouts — commonly 60 s — and the protocol's answer is
`notifications/progress`, which many clients use to reset that timer. **That mechanism is not
reliable enough to depend on**: several clients and SDKs have known defects where the timer is not
reset on progress, or where the progress callback is never wired through.

`R-MCP-11` The server **MUST** implement both layers:

- **Layer A — progress.** If `params._meta.progressToken` is present, emit `notifications/progress`
  every 5 s while waiting, with a `message` reflecting the `turn.progress` phase reported by the
  daemon ("Listening…", "User is composing…", "Speaking the response…"). `progress` increments
  monotonically; `total` is omitted, since the wait has no known length.
- **Layer B — bounded wait with continuation.** Regardless of Layer A, no single `converse` call
  waits longer than `VOICECHAT_TURN_WAIT_MS` (default **240 000**, minimum 10 000). When it
  elapses, the call **returns** `status:"waiting"` with a continuation token instead of continuing
  to block.

`R-MCP-12` Layer B **MUST NOT** be disabled by the presence of a progress token. Layer A reduces how
often the loop visibly round-trips; Layer B is what guarantees the call always returns before any
client's timeout. Correctness rests on B alone.

`R-MCP-13` The bounded wait **MUST NOT** advance the turn, display anything, or change the window in
any way. From the person's point of view a `waiting` cycle is invisible.

### 4.6 Cancellation and shutdown

`R-MCP-14` On `notifications/cancelled` for an in-flight `converse`, the server **MUST** send
`session.close(reason: "host_cancelled")` and stop. The window shows a terminal banner
([§6.9](#69-terminal-and-error-presentation)). Cancellation ends the session rather than the turn:
a half-cancelled turn is precisely the desynchronised state this design exists to prevent.

`R-MCP-15` On `stdin` EOF, `SIGTERM`, or `SIGINT`, the server **MUST** send
`session.close(reason: "mcp_exit")` and exit within 2 s.

`R-MCP-16` If the daemon becomes unreachable mid-call, the tool **MUST** fail with a message naming
the socket path and suggesting relaunching VoiceChat. It **MUST NOT** retry silently.

### 4.7 Streamable HTTP transport

*Status: implemented, opt-in, off by default — see the open issue at the end of this section before
relying on it.*

Everything in this section is a second way to reach the **same** `converse` tool ([§4.2](#42-the-converse-tool)),
not a second tool or a second contract. An MCP client that speaks HTTP rather than spawning a stdio
child process — a web-based agent, for instance — can drive VoiceChat exactly as `voicechat-mcp`
does, without any host-side process management at all.

`R-MCP-18` The tool's schema, description, and result-rendering **MUST** be defined once
(`ConverseTool`, in `VoiceChatKit`) and consumed identically by both transports. A person or a model
comparing `tools/list` output between `voicechat-stdio` and `voicechat-http` **MUST** see
byte-identical text — confirmed by the manual verification of [§15.4](#154-manual-acceptance-checklist).

**Shared engine, two gateways.** The state machine behind `converse` — turn/continuation bookkeeping,
the restart-after-`ended` behaviour of `R-MCP-17` — is `ConverseSessionEngine` (`VoiceChatKit`), an
actor generic over a `ConverseSessionGateway` protocol (`openSession`/`awaitTurn`/`closeSession`/
`discardSession`). Two conformances exist:

| Gateway | Reaches a session by | Lives in |
|---|---|---|
| `VCPSessionGateway` | VCP, over the Unix socket, exactly as before | `voicechat-mcp` |
| `InProcessSessionGateway` | Calling `DaemonServer`/`Session`/`TurnCoordinator` directly — no socket, no JSON-RPC framing | `VoiceChatMCPServer` |

`R-MCP-19` The HTTP transport **MUST** reach a session in-process, never by connecting to VCP as a
second client of itself. `TurnCoordinator.awaitTurn` is already transport-agnostic
(the daemon's own VCP dispatch calls it the same way); routing HTTP through VCP as well would only
add a socket hop with no benefit and a second, redundant trust boundary.

**Transport itself.** The Streamable HTTP transport (2025-03-26 MCP spec revision: a single `/mcp`
endpoint, POST for client→server messages with an SSE-streamed response, GET for a standalone
server→client stream, `Mcp-Session-Id` for session identity, `DELETE` to end a session) is the
swift-sdk's own `StatefulHTTPServerTransport`, unmodified. VoiceChat supplies only the socket
listener — a SwiftNIO adapter, `HTTPApp` (`VoiceChatMCPServer`), closely adapted from the SDK's own
reference implementation — and the one thing the reference has no analogue for: a per-session
`onClose` hook. Without it, `DELETE`, an idle timeout, or the app quitting would tear down the HTTP
session bookkeeping while leaving that conversation's window open forever; `onClose` calls
`engine.shutdown(reason:)`, which reaches the real `Session` and closes it, exactly as `R-APP-7`
requires for any other path to disposal.

`R-MCP-20` One `Server` (with the `converse` tool registered), one `ConverseSessionEngine`, and one
`InProcessSessionGateway` — and therefore one conversation window — **MUST** exist per
`Mcp-Session-Id`. Multiple HTTP clients, or one client opening multiple sessions, open multiple
independent windows; there is no enforced cap today (a documented gap, not a decision).

**Binding and enablement (`R-APP-8`).** The listener **MUST** bind `127.0.0.1` only, never
`0.0.0.0`, hardcoded rather than configurable. It does not start automatically unless
`VOICECHAT_MCP_HTTP_PORT` is set at launch (which also selects the port); otherwise, the menu bar
carries a checkable **"Streamable HTTP (port …)"** item ([§10](#10-menu-bar-applet)) that starts and
stops it on demand, defaulting to port 8765. A bind failure (e.g. the port already taken) is reported
with an alert when triggered by that menu item, and logged (not shown) when it happens during
automatic startup — the same asymmetry `R-ARCH-3` draws between VCP (fatal if it can't start) and
this transport (secondary; VCP already succeeded).

`R-SEC-8` A TCP listener on loopback, even with the SDK's built-in Origin/Host validation
(`OriginValidator.localhost()`, applied by default), is reachable by **any local user account** on
the machine, not only the one that launched VoiceChat — a real downgrade from VCP's `0600` socket in
a `0700` directory (`R-SEC-3`). This is accepted as the inherent cost of a TCP-based transport at
all, stated plainly rather than engineered around; it is the reason this transport is opt-in. A
shared-secret validator (the SDK ships `BearerTokenValidator` as a ready template) is a natural
future addition, not built here.

**Known open issue.** A bare `converse()` call over this transport has been observed to return
`status: "ended"` immediately, with no window ever opening — reproduced even against a freshly
issued `Mcp-Session-Id` with no prior turns, isolating it from the reconnect-reuse behaviour
`R-MCP-17` is specifically designed to handle. The cause is not yet identified. Until it is, treat
the HTTP transport as unverified for fresh sessions despite the passing end-to-end test recorded in
[§15.4](#154-manual-acceptance-checklist) — that test evidently does not cover whatever this
condition depends on.

---

## 5. Session and turn state machine

This section is the authority for every enable/disable, every microphone transition, and every
window change. Implementations **MUST** derive UI state from it rather than setting controls
ad hoc.

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
finishes. This latch is the mechanism behind the v1.0 rule that, once stopped, the response stays
on screen however many times it is replayed.

`R-FSM-2` The manual latch **MUST** reset at every turn boundary. Each turn begins in
`Responding.Auto` when its response arrives, regardless of what happened in the previous turn.

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
| 14 | any non-terminal | **End conversation** / ⌘W / ⌥⌘E | `Ended` | stop | — | stop | — |
| 15 | any non-terminal | `session.close` from peer | `Ended` | stop | — | stop | — |
| 16 | any non-terminal | VCP peer disconnect | `Ended` | stop | — | stop | — |

Row 8 implements the v1.0 sentence *"If the TTS runs out of text to read, then switch to next prompt
composition turn."* Row 11 implements *"Even if the full response is read, the response mode
stays."* Row 13 implements *"In manual mode only 'Got it' finishes the response."*

### 5.3 Invariants

Each of these is directly assertable in tests.

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
| Response is empty or whitespace only | Row 7: no TTS, no `Responding` state, advance directly to the next turn. Avoids a dead-end state with nothing to read and nothing to acknowledge. |
| **Send** pressed in the same runloop turn as an incoming `session.ended` | `Ended` wins. The prompt is discarded and the person is shown the closing banner. |
| Person edits the response pane, then presses `Play` | Speech is rebuilt from the **current** pane contents ([§9.2](#92-deriving-spoken-text)). |
| TTS fails to start (no voice installed, audio device lost) | Treated as `didFinish`: row 8 or 11 applies, and a warning chip appears in the right footer. A broken speaker must never strand the conversation. |
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

`R-UI-1` The header's subtitle line **MUST** track session state, as the equivalent of the reference
implementation retitling its window (`NSWindow.title` still carries the title for Mission Control and
accessibility):

| State | Subtitle |
|---|---|
| `Composing` | `Composing · turn 3` |
| `Composing`, mic live | `Listening · turn 3` |
| `Submitted` | `Waiting for the assistant…` |
| `Responding.Auto` | `Speaking · turn 3` |
| `Responding.Manual` | `Paused · turn 3` |
| `Ended` | `Conversation ended` |

`R-UI-2` The header carries, trailing, a theme control of three icon buttons — **Default** (half-filled
circle; follows the system appearance), **Light** (sun), **Dark** (moon) — persisted in `UserDefaults`
(`VoiceChatTheme`, default `system`) and applied to every conversation window through `NSWindow.appearance`.
Next to it sits a transparency slider (0 = as see-through as the glass gets, 1 =
nearly solid; default 0.35). It scales only the backdrops — the window wash and the editor-card fill — never
text or controls. The value is shared by all conversation windows and persisted in `UserDefaults`
(`VoiceChatGlassOpacity`). The header also carries, leading, a close button (same effect as closing a titled window: a live
session ends with `window_closed`), and, between the title and the theme control, the identity badge
above — purely decorative text, hidden when absent. It **MUST NOT** carry Send, Play, Stop, or Got it! —
those belong to their panes. The speech-output popover and settings button of the earlier toolbar design are not
implemented.

Beside the pin sits a layout button (⌥⌘L) that arranges the two panes side by side or stacked, prompt
above response. Its icon shows the layout a click switches to, not the current one, which is already
visible. Between the panes is a divider the person drags to set the proportion; double-clicking it
splits the space evenly. It never lets a pane shrink below its minimum (420 pt wide side by side, 180 pt
tall stacked). The layout and a separate proportion for each layout are shared by all conversation windows
and persisted in `UserDefaults` (`VoiceChatPaneLayout`, default side by side; `VoiceChatSideBySideSplit`
and `VoiceChatStackedSplit`, default 0.5).

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

`R-UI-4` The active pane **MUST** be indicated by the focus ring described above — the native
reading of the reference implementation's purple glow. The inactive pane shows only its 1 pt border.
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

Placeholder when empty: `Waiting for the response…` while `Submitted`, otherwise `The response will appear here.` The pane is editable only while `Responding`; before a response arrives there is nothing to edit, and text typed there would be neither sent nor played.

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
| `R-UI-11` | Selecting a past turn loads its prompt and response into the two panes and shows a prominent `Return to current turn` bar across the top of the split view. The **response** pane is always read-only while peeking — what was already said is immutable. The **prompt** pane follows its normal per-state rule ([§6.6](#66-control-enablement-matrix)): editable in `Composing`, otherwise not. Peeking does not itself restrict dictation, the mic toggle, or the mode control (R-UI-27). |
| `R-UI-12` | Returning restores the live turn's content exactly, including unsent draft text and cursor position — **unless** the peeked prompt was edited and sent (R-UI-27), in which case the send supersedes the draft and there is nothing to return to restore. |
| `R-UI-13` | History covers the **current conversation only**. It is held in memory and discarded when the session ends. |
| `R-UI-14` | **Export…** writes a Markdown transcript to a user-chosen location via `NSSavePanel`. This is the only path by which conversation content reaches disk. |
| `R-UI-29` | When the MCP client declares the `roots` capability, the server asks it for its roots (`roots/list`) and forwards them to the window, refreshing on `notifications/roots/list_changed`. The bottom bar then shows a folder chip with the count, opening a popover that lists each root's name and path, each revealable in the Finder. The fetch is off the conversation's path and abandoned after 5 s, so a host that answers slowly or not at all never delays a turn; a host reporting no roots, or not supporting them, shows no chip. |
| `R-UI-27` | A past prompt is not a museum piece: while it is loaded and the session is in `Composing`, it can be edited and sent like any other prompt, producing a new turn. This is deliberately not "read-only history" — the only immutable half of a past turn is the response that was actually said. |

### 6.6 Control enablement matrix

`R-UI-15` Control state **MUST** be derived from this table. It makes the greyed-out states visible
in the reference screenshots normative.

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

This matches **Ref-A** (Send prominent, Play/Stop/Got it! inert) and **Ref-B** (mic controls and
Send greyed, Stop and Got it! live, Play greyed while speaking).

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
appearance (light or dark), and the highlight is `systemCyan` (deepened for text on light glass) rather
than the user's accent colour — the holographic look is the point of the shell.

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
| ⌘, | Settings | App-wide |

`R-UI-19` **End conversation** ends the session immediately, with no confirmation, regardless of
unsent text or in-progress speech — a confirmation on every close was judged to be more friction than
the loss it would prevent, since the conversation is still visible in the history strip and, if the
prompt is worth keeping, can be resent from there (`R-UI-27`).

### 6.9 Terminal and error presentation

`R-UI-20` On entering `Ended`, the window **MUST** show a non-modal banner across the top of the
split view naming the reason — `Conversation ended.`, `The assistant cancelled this conversation.`,
`VoiceChat lost contact with the assistant.` — dim both panes to read-only, and close automatically
after 4 s. The bottom bar's **End conversation** button is replaced by an always-enabled **Close**
button for the rest of the window's life, so the window can be dismissed on demand regardless of the
auto-close timer — this, not a button embedded in the banner itself, is where dismissal lives.
Auto-close is suppressed while the history strip is expanded, so a transcript can still be exported;
**Close** remains available throughout, since a suppressed timer must never be the only way out
(`R-APP-7`).

`R-UI-21` Recoverable problems (mic denied, no voice installed, recogniser unavailable) **MUST**
appear as an inline row inside the affected pane's footer with a one-line explanation and a single
action button. They **MUST NOT** use modal alerts, which would block a conversation that is still
perfectly usable.

### 6.10 Accessibility

| | |
|---|---|
| `R-UI-22` | Every control carries an accessibility label and, where its meaning is state-dependent, a value. The two text views are labelled `Prompt` and `Response`. |
| `R-UI-23` | State changes post `NSAccessibilityPriorityAnnouncement` announcements: "Listening", "Sending", "Speaking", "Response finished", "Conversation ended". |
| `R-UI-24` | When VoiceOver is running, automatic playback of responses **MUST** default to off — VoiceOver and `AVSpeechSynthesizer` speaking simultaneously is unusable. The first time this is applied the person is told once, in the right pane footer, with a control to override. With auto-play off, row 6 of [§5.2](#52-transition-table) enters `Responding.Manual` directly. |
| `R-UI-25` | Full keyboard navigation between panes, footers, history, and the bottom bar via Tab / ⇧Tab, with a visible focus ring on every stop. |
| `R-UI-26` | All text honours the system text size where the platform supports it, and no control has a fixed height that would clip enlarged text. |

---

## 7. Text model

### 7.1 Rich text in both panes

`R-TXT-1` Both panes **MUST** be `NSTextView` instances using TextKit 2 (`NSTextLayoutManager`) over
an `NSTextStorage`, matching the API bindings already named in `Commands and Dictation.md`, and
**MUST** hold attributed text rather than plain strings. `Bold that`, `Italicise that`, and
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

`R-TXT-3` The original Markdown **MUST** be retained alongside the attributed string as
`sourceMarkdown`, for export and for the raw-text view. It is not re-derived from the attributed
string.

`R-TXT-4` Malformed Markdown **MUST NOT** fail the turn. On a conversion error the raw text is
displayed verbatim as plain body text and a debug-level log entry is written.

### 7.3 Outbound: attributed → Markdown

`R-TXT-5` On **Send**, the prompt pane is serialised to Markdown by a `MarkdownSerializer`
supporting a deliberately small subset: bold, italic, underline (as `<u>`), inline code, and fenced
code blocks. Everything else is emitted as plain text.

`R-TXT-6` Text that carries no formatting attributes **MUST** serialise byte-identically to what was
typed or dictated. A person who never uses a formatting command never sees Markdown syntax appear in
what they send.

`R-TXT-7` Literal Markdown metacharacters typed by the person (`*`, `_`, `` ` ``, `#` at line start)
**MUST NOT** be escaped. Someone who types `2 * 3 * 4` means exactly that, and models handle the
ambiguity better than an escaping scheme would.

### 7.4 Right-pane edits

`R-TXT-8` Edits to the response pane are **local only**. They change what speech reads
([§9.2](#92-deriving-spoken-text)) and what the transcript exports, and are **never** sent back to
the model. Because both panes are editable, this is stated explicitly rather than left to be
inferred.

`R-TXT-9` The history strip records the response **as received**, not as edited, so the transcript
reflects what the model actually said. An edited response is marked `(edited)` in the strip.

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
with a `MockSpeechEngine` that emits scripted volatile and finalised results. This exists so the
entire command vocabulary is testable without a microphone (goal G6), not for OS portability.

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

The current mode is visible in three places simultaneously: the segmented control, the left header
chip, and the window subtitle. Mode is the single most consequential piece of hidden state in the
app — saying an editing command while in Dictation mode types it as prose — so it is deliberately
over-indicated.

### 8.5 Command dispatch contract

`Commands and Dictation.md` enumerates the vocabulary. This section defines how it is applied. The
two together are the complete specification; neither is sufficient alone.

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
affected pane and, if enabled, plays the system error sound. Silently typing an unrecognised command
into the document defeats the entire purpose of having a command mode, and is the failure people
find hardest to undo.

**Undo.** `R-STT-15` Every document mutation, from both modes, **MUST** be registered with the text
view's `UndoManager` as a single coalescible action named after the command, so that `Undo that` and
`Redo that` work over voice edits exactly as ⌘Z does over typing.

**Session controls while a pane is not focused.** `R-STT-16` Session controls dispatch to the
session regardless of which pane holds focus. Editing, selection, navigation, and deletion commands
apply to the focused pane, which is determined by state per `R-FSM-6`.

**Availability.** `R-STT-17` A command that is unavailable in the current state — `Send prompt`
outside `Composing`, `Play` while already speaking — **MUST** be reported as
`Not available right now`, distinctly from `Unrecognised command`. Conflating the two makes a
correctly-spoken command look like a recognition failure.

**Coverage.** `R-STT-18` Every phrase in `Commands and Dictation.md` **MUST** have an implementation
and at least one test ([§15.2](#152-required-tests)). Adding a phrase to that document without an
implementation is a defect in this system, not a gap in the document.

*Implementation notes (P4).* `Commands and Dictation.md` leaves a handful of behaviours
underspecified; these are the resolutions, chosen for consistency and confirmed by test:

- **`line`**, wherever it names a unit (`Select line`, `Delete previous line`, …), means the current
  *logical* line — the extent between `\n` boundaries — not the visually wrapped line a real text
  view would show. The wrapped extent depends on window width, which has no meaning in the headless
  `TextDocument` double that backs the per-phrase tests (`R-STT-18`), so the logical line is the one
  definition that is both real and testable.
- **`Select that`** is the one selection command that may act with nothing currently selected: it
  falls back to the word nearest the caret, so a person can create an initial selection by voice
  before using `that` in a later command. Every other `that` target (`Delete that`, `Bold that`,
  `Cut that`, `Correct that`, …) requires an existing, non-empty selection and reports
  `Nothing selected` otherwise — expanding what "that" means to fix an editing or deletion command
  onto an unintended word would be a correctness hazard, not a convenience.
- **`Capitalise` / `Italicise`** also accept the American spellings `Capitalize` / `Italicize` as
  synonyms; `Commands and Dictation.md` is not amended, since the recognised vocabulary is a superset
  of what it documents, never a departure from it.
- **`Replace <phrase> with <phrase>`** splits its utterance on the *last* standalone occurrence of
  the word `with` (as specified); `Insert <phrase> after/before <phrase>` applies the same
  last-occurrence rule for `after`/`before`, by extension, since the document does not specify a
  split rule for this command family and consistency was preferred over an arbitrary alternative.

### 8.6 Custom vocabulary

`R-STT-19` `Add to vocabulary` **MUST** take the current selection (or, if the selection is empty,
the word under the insertion point), persist it into `VocabularyStore`
(`~/Library/Application Support/VoiceChat/vocabulary.json`), and apply the updated phrase list to the
active transcriber, taking effect on the next recogniser start at the latest.

`R-STT-20` The store is capped at 100 phrases, most-recently-added first, matching the platform
guidance for contextual phrase lists. Phrases are kept short — one or two words. The list is
editable in Settings ([§11](#11-settings)).

*Binding note (C3).* `Commands and Dictation.md` names
`SFVocabulary.shared().setCustomVocabularyStrings(…, for: .userContext)`. That call does not exist in
the Speech framework; the signature belongs to SiriKit's `INVocabulary`. The macOS 26 equivalent was
confirmed against the SDK and **MUST** be used instead:

```swift
let context = AnalysisContext()
context.contextualStrings[.general] = phrases     // ≤ 100, short
try await analyzer.setContext(context)            // or pass via init(inputSequence:…)
```

The `SFSpeechRecognizer`-generation equivalent, for reference, is
`SFSpeechRecognitionRequest.contextualStrings` (or `SFSpeechLanguageModel` for a trained model).

`R-STT-21` *Retired.* This requirement described a post-recognition fuzzy-correction fallback for
the case where the transcriber exposed no contextual-phrase input. That case does not arise:
`AnalysisContext.contextualStrings` exists. Per [§0.1](#01-requirement-language) the identifier is
retired, not reused.

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

`R-STT-25` Authorisation **MUST** be requested at first microphone activation, never at launch. A
permission prompt before the person has asked for anything is both hostile and likely to be denied.

`R-STT-26` Denial **MUST NOT** degrade anything other than speech. The window, typing, all buttons,
and the full conversation loop keep working; the footer shows one line and an **Open System
Settings…** button that deep-links to the Privacy pane.

---

## 9. Speech output

### 9.1 Synthesis

`R-TTS-1` Playback **MUST** use `AVSpeechSynthesizer` with a locally installed voice. No network
voice, no third-party engine.

`R-TTS-2` The response **MUST** be split into sentence-level utterances
(`String.enumerateSubstrings(in:options:[.bySentences, .localized])`) and enqueued in order, rather
than spoken as one utterance. This gives immediate response to **Stop**, accurate progress
reporting, and per-sentence highlighting.

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
can be translated into a document range for highlighting (`R-UI-8`). Skipped content occupies a
segment with no utterance, so highlighting does not drift out of alignment over a long response.

`R-TTS-8` A response longer than 20 000 characters is truncated for speech at the last sentence
boundary before the limit, and a final utterance says `Response truncated for reading.` The full
text remains visible in the pane.

### 9.3 Microphone interlock

`R-TTS-4` The recogniser **MUST** be stopped and the input tap removed **before** the first
utterance is enqueued, and **MUST NOT** be restarted until `didFinish` or `didCancel` is received.
This is the resolution of conflict **C1** and the mechanism that prevents the synthesised response
from being transcribed as the next prompt.

`R-TTS-5` On `didFinish` or `didCancel` the recogniser restarts in:

- **Command** mode, if the state is `Responding.Manual`;
- **Dictation** mode, if the state has advanced to `Composing`.

This is the reading of `Play` "locks voice to Command Mode" from `Commands and Dictation.md`: the
mode is what playback returns to.

`R-TTS-9` The interlock **MUST** be implemented as a single owner of the audio session — a
`AudioRouteCoordinator` through which both controllers acquire and release the device — so that the
invariant cannot be broken by a missed callback. Re-entrancy (a second `Play` while stopping) must
not leave the tap installed.

### 9.4 Auto and manual modes

Restating the v1.0 rules as they appear in [§5.2](#52-transition-table):

| | |
|---|---|
| `R-TTS-10` | A response begins playing automatically on arrival (`Responding.Auto`), except when `R-UI-24` applies. |
| `R-TTS-11` | Finishing naturally in `Responding.Auto` advances to the next turn. |
| `R-TTS-12` | **Stop** latches the turn into `Responding.Manual` permanently. |
| `R-TTS-13` | In `Responding.Manual`, **Play** and **Stop** may be used any number of times, and finishing naturally does **not** advance the turn. |
| `R-TTS-14` | **Got it!** is the only way out of `Responding.Manual`. |

`R-TTS-15` **Play** in `Responding.Manual` starts from the beginning of the response, unless there
is a non-empty selection, in which case it reads the selection only. Resuming mid-response is not
offered; it is ambiguous after an edit, and restarting is cheap.

---

## 10. Menu bar applet

`R-APP-1` The app **MUST** run as `LSUIElement` with no Dock icon and no main menu-bar application
menu, presenting a single `NSStatusItem`.

Icon: `waveform.circle`, switching to `waveform.circle.fill` while any session is open, with a
subtle pulse while any session is speaking (suppressed under Reduce Motion).

Menu, as designed:

```
  VoiceChat 2.0
  ─────────────────────────────────
  Idle  /  2 conversations open
    ▸ claude-code — turn 3 · Speaking
    ▸ WebStorm — turn 1 · Composing
  ─────────────────────────────────
  Test Conversation…                 ⌥⌘T
  ─────────────────────────────────
  Microphone       Allowed
  Speech Recognition   Not determined
  Permissions…
  ─────────────────────────────────
  Settings…                            ⌘,
  Show Log
  Start at Login                        ✓
  ─────────────────────────────────
  Quit VoiceChat                       ⌘Q
```

Menu, as built — the session list and Test Conversation are implemented as designed; the
permissions rows, Settings, Show Log, and Start at Login are not implemented (they depend on
[§11 Settings](#11-settings), also not yet built, and on the logging story in
[§12.3](#123-logging), which is simpler than designed):

```
  VoiceChat 0.0.2
  ─────────────────────────────────
  2 conversations open
      claude-code — turn 3
      WebStorm — turn 1
  ─────────────────────────────────
  Test Conversation…              ⌥⌘T
  ─────────────────────────────────
  ✓ Streamable HTTP (port 8765)
  ─────────────────────────────────
  Quit VoiceChat
```

The Streamable HTTP item ([§4.7](#47-streamable-http-transport)) is the one addition beyond the
original design: a checkable toggle, checked while the transport is listening.

| | |
|---|---|
| `R-APP-2` | Selecting a session in the list focuses its window. |
| `R-APP-3` | **Test Conversation…** opens a conversation window backed by a loopback session with no MCP host: prompts are echoed back as responses after a short delay. This is the primary manual-testing affordance and **MUST** ship in release builds — it is how a person verifies microphone, voice, and commands without configuring a host. |
| `R-APP-4` | *Not implemented.* No permission rows or **Permissions…** item exist; there is no menu-driven way to check or jump to TCC status today. |
| `R-APP-5` | *Not implemented.* No **Start at Login** item; `SMAppService` is not wired up. The app must be launched manually or via the MCP server's auto-launch (`R-ARCH-3`). |
| `R-APP-6` | **Quit** ends every open session first via `applicationWillTerminate` — each resolves its `turn.await` with `ended` — and only then terminates, so no host is left with a hanging tool call. The single-confirmation-naming-the-count behaviour for unsent text is *not implemented*; Quit is immediate and unconditional. |
| `R-APP-7` | A session is removed from this list, and its window and model become deallocatable, only when its window actually closes — not merely when the conversation ends. Ending a conversation (by any means) leaves its window showing a terminal banner and a **Close** button until the window itself is dismissed (immediately for a person-initiated end, after a short delay otherwise, or on demand via **Close**); only that closing is true disposal. Until then the ended session still counts toward "N conversations open" and can still be brought back to the front from this menu — that is expected, not a leak. |
| `R-APP-9` | **MCP Server Config…** opens a small dialog showing a sample client configuration (`.mcp.json` format) for both transports: the `stdio` entry is always `/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp` (the standard install location, not derived from where the app is running), and the `streamable-http` entry at `http://127.0.0.1:<port>/mcp`. **Copy** puts the JSON on the clipboard (the button reads `Copied` for 1.5 s); **Save…** writes it to a user-chosen `.json` file via `NSSavePanel`. Reopening while it is showing brings the existing dialog forward. |
| `R-APP-8` | The **Streamable HTTP** item toggles [§4.7](#47-streamable-http-transport)'s listener on and off live, with no relaunch. It starts pre-checked only when `VOICECHAT_MCP_HTTP_PORT` was set at launch; otherwise it is unchecked and the port shown is the built-in default (8765). Toggling it off must fully release the port and its background tasks so toggling it back on repeatedly does not leak either — not just close the visible connections. |

---

## 11. Settings

*Status: not yet implemented (P5, [§16](#16-implementation-phases)).* There is no Settings scene
today; the behaviours below (vocabulary editing, voice/rate selection, `waitMs` override, and the
per-conversation-ending confirmation option) do not exist as user-facing controls. `VocabularyStore`
already persists to `~/Library/Application Support/VoiceChat/vocabulary.json` per `R-STT-19`/`20`,
so only the editor UI is missing there; ending a conversation currently has no confirmation at all,
in any circumstance (`R-UI-19`), rather than the three-way choice described here.

A standard `Settings` scene with four panes.

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

*Status: much simpler than designed.* Nothing below the line uses `os.Logger`, structured
categories, file rotation, or a **Show Log** affordance ([§10](#10-menu-bar-applet)). The MCP server
writes one-line, unconditional diagnostics (`converse -> <status>`, failures) to `stderr` only, via a
plain `FileHandle.standardError.write` — satisfying the load-bearing half of `R-LOG-2` (never
`stdout`, so the JSON-RPC channel is never corrupted) without the file-logging half. The daemon
(`voicechatd`) does not log anything at all today. The original design is kept below as the target
for a future pass, since desync diagnosis without a persistent log is real debt, not a stylistic gap.

| | |
|---|---|
| `R-LOG-1` | *Not implemented.* `os.Logger`, subsystem `dev.sandipchitale.voicechat`, categories `vcp`, `mcp`, `session`, `stt`, `tts`, `ui`. |
| `R-LOG-2` | *Partially implemented* — see above. The MCP server logs to `stderr`; not to `~/Library/Logs/VoiceChat/mcp-<pid>.log`. **Never** to `stdout` (`R-MCP-3`) — this part holds. |
| `R-LOG-3` | Holds vacuously: the only things currently logged are a status word and error descriptions, never prompt or response text, so there is nothing that needs a `privacy: .private` marking yet. |
| `R-LOG-4` | *Not implemented.* No **Show Log** item, no log directory, no rotation. |
| `R-LOG-5` | *Not implemented.* State transitions are not logged; a desync today can only be diagnosed by reproducing it live. |

---

## 13. Security and privacy

| | |
|---|---|
| `R-SEC-1` | Audio is captured, transcribed, and synthesised entirely on-device. VoiceChat makes no network connections of any kind. |
| `R-SEC-2` | No prompt, response, or transcript is written to disk unless the person explicitly exports one (`R-UI-14`). |
| `R-SEC-3` | The socket is mode `0600` inside a mode `0700` directory, and the peer uid is verified (`R-VCP-5`). Any local process running as the same user can open a conversation window; this is the same trust boundary as the MCP host itself, and is stated plainly rather than implied. |
| `R-SEC-4` | `continuation` tokens are authenticated against server-side state (`R-MCP-6`) and are meaningless to any other process. |
| `R-SEC-5` | Spoken content reaching the model is delimited (`R-MCP-9`). VoiceChat does not otherwise filter or moderate what the person says. |
| `R-SEC-6` | The `com.apple.security.device.audio-input` entitlement is in place. Hardened runtime, a Developer ID signature, and notarisation are **not** — the current build is ad-hoc signed only ([§16](#16-implementation-phases) P6, [SETUP.md](SETUP.md)), which is why the microphone/speech permission grant does not survive every rebuild. |
| `R-SEC-7` | *Not implemented* — depends on the Settings scene ([§11](#11-settings)), which does not exist yet. |

---

## 14. Build, packaging, installation

### 14.1 Prerequisites

`R-BLD-1` The Xcode licence must be accepted before anything builds:

```bash
sudo xcodebuild -license
```

*Resolved.* This blocked the very start of implementation and is noted here only because the spec
originally flagged it as an open risk; it is a one-time step on any new machine, not an ongoing
concern.

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

`R-BLD-2` *As built, this is simpler than originally planned:* there is no Xcode project at all.
`voicechatd` and `voicechat-mcp` are ordinary SwiftPM executable targets, and
[`Scripts/make-app.sh`](Scripts/make-app.sh) assembles `VoiceChat.app` directly — copying
`App/Info.plist`, the two built executables (`voicechatd` renamed to `Contents/MacOS/VoiceChat`,
per `CFBundleExecutable`), and ad-hoc signing both the inner `voicechat-mcp` and the outer bundle
with its entitlements. This still satisfies the original intent (TCC authorisation, `LSUIElement`,
and code signing all need a real bundle, while the testable core is a plain library `swift test` can
run with no bundle at all) with less machinery: no separate project file to keep in sync with the
package, and no Xcode dependency for a routine rebuild.

`R-BLD-3` `Scripts/make-app.sh` **MUST** copy the same build's `voicechat-mcp` into
`VoiceChat.app/Contents/MacOS/`, so the app and the server can never drift to different versions —
enforced by construction (one script, one build, two copies) rather than by a version-string check
at runtime.

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
`VOICECHAT_TURN_WAIT_MS` (bounded-wait duration, clamped to a 10 s minimum). `VOICECHAT_LOG_LEVEL` is
not implemented — logging is unconditional per [§12.3](#123-logging), with no level to override.

A host that speaks Streamable HTTP ([§4.7](#47-streamable-http-transport)) instead can be registered
alongside, or instead of, the stdio entry — both reach the same daemon and the same `converse` tool:

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

The `voicechat-http` entry only connects once the menu bar's **Streamable HTTP** item is checked, or
`VOICECHAT_MCP_HTTP_PORT` was set before launch (`R-APP-8`) — unlike `voicechat-mcp`, nothing
auto-launches this side for you.

---

## 15. Testing and acceptance criteria

### 15.1 Strategy

`VoiceChatKit` contains the state machine, the protocol codec, the command dispatcher, the Markdown
conversions, and the speech-text builder, and imports no UI framework (`R-ARCH-5`). Nearly every
requirement in this document is therefore testable with `swift test`, with no window and no
microphone.

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
23. Checking **Streamable HTTP** in the menu bar starts it; a client registered as `streamable-http`
    against `http://localhost:<port>/mcp` can `initialize`, list `converse` with schema/description
    identical to the stdio tool, call it, get a window, exchange turns, and `DELETE` its session,
    closing that window. `R-MCP-18`–`R-MCP-20`, `R-APP-8` — **but see the open issue in
    [§4.7](#47-streamable-http-transport): this sequence has passed, and a bare `converse()` on a
    fresh session has also independently failed immediately with no window at all. The checklist
    item is not yet reliably green.**

---

## 16. Implementation phases

Each phase ends in something runnable and demonstrable.

| Phase | Deliverable | Done when | Status |
|---|---|---|---|
| **P0 — Skeleton** | Package + Xcode project, `LSUIElement` app, status item, empty window, logging. | The app launches, shows a menu bar icon, and opens an empty window from the menu. | ✅ Done |
| **P1 — The loop, typed** | VCP (codec, listener, client), `session.open` / `turn.await`, MCP server with `converse`, state machine, both panes, Send / Got it! / End conversation, bounded wait + continuation. **No speech at all.** | A host runs a complete multi-turn typed conversation; `R-VCP-7`–`R-VCP-12` and the full state machine test suite pass. | ✅ Done |
| **P2 — Output** | Markdown → attributed rendering, `AVSpeechSynthesizer`, sentence segmentation, highlighting, Play / Stop / Got it! semantics, Auto vs Manual latch. | Responses render and read aloud; rows 6–13 of [§5.2](#52-transition-table) verified by hand and by test. | ✅ Done |
| **P3 — Dictation** | `SpeechAnalyzer` pipeline, permissions, mic toggle, volatile/finalised handling, the interlock, device arbitration. | A full conversation is held by voice except for command mode; `R-FSM-3`/`R-FSM-4` hold under the interlock tests. | ✅ Done |
| **P4 — Command mode** | The command table, normalisation, `<count>` and `<phrase>` resolution, precedence, dispatcher, undo integration, vocabulary store. The largest phase. | Every phrase in `Commands and Dictation.md` has an implementation and a passing test (`R-STT-18`). | ✅ Done — `TextUnits`, `TextDocument`, `EditCommand`, `TextCommandParser`, `TextCommandExecutor` (`VoiceChatKit`), `NSTextViewDocument` (`VoiceChatUI`) |
| **P5 — Fit and finish** | History strip, export, settings panes, menu bar session list, Test Conversation, accessibility pass, error catalogue. | The manual acceptance checklist passes end to end. | 🟡 Partial — history strip, export, menu bar session list (with true window-close disposal, `R-APP-7`), and Test Conversation are done; **settings panes ([§11](#11-settings)) do not exist yet**, and the accessibility pass and error catalogue are unverified |
| **P6 — Ship** | Signing, hardened runtime, notarisation, version-match build check, install and host-registration documentation. | A notarised `.app` installs on a clean machine and works from a single `claude mcp add`. | ⬜ Not started — ad-hoc signed only; see [SETUP.md](SETUP.md) |
| **P7 — Streamable HTTP transport** *(addendum — not in the original P0–P6 plan)* | A second, opt-in MCP transport reaching `converse` in-process, sharing the tool contract and turn engine with stdio ([§4.7](#47-streamable-http-transport)), plus a menu bar toggle (`R-APP-8`). | `tools/list` matches the stdio tool byte-for-byte; a full turn exchange and session teardown work over HTTP. | 🟠 Built, but **not reliable**: manual checklist item 23 has both passed in full and failed immediately (no window, instant `ended`) on a freshly issued session. Root cause not yet found. |

---

## 17. Debate

A debate is the ordinary conversation loop with the person's half automated: two MCP clients argue a
motion, and each one's finished statement becomes the other's incoming prompt. The person creates the
room and moderates it.

`R-DEB-1` The relay **MUST** hang off the turn advancing (`SessionEffects.advancesTurn`, rows 7, 8
and 13 of [§5.2](#52-transition-table)), never off speech finishing. Auto-play is off under VoiceOver
and where no voice is installed (`R-UI-24`), and a moderator may cut a statement short with Stop then
**Got it!** — in both cases speech never finishes, and a relay hung off it would strand the debate
silently.

`R-DEB-2` Muting **MUST NOT** change a debate. `R-TTS`-level muting leaves the reading, the sentence
highlight and the turn advance running, so a moderator can silence both windows and follow the
argument by the highlight alone, at the same pace. No relay may be triggered by audio state, an audio
tap, or an estimated reading duration.

`R-DEB-3` There is **no speech arbiter**. Stopping one seat's synthesiser from outside the state
machine would leave that seat in `Responding.Auto` for ever (its cancellation deliberately does not
re-enter the machine), which is the very stall an arbiter would be added to prevent. A debate
alternates by construction.

`R-DEB-4` The person creates a room from the menu bar; clients only join. Nothing opens until a seat
is taken, so no window is ever orphaned waiting for a client that never comes.

`R-DEB-5` A client takes a seat by passing `debate_id` and `side` on its **first** `converse` call.
A refusal — unknown room, unknown seat, seat taken — **MUST** be an actionable sentence naming the
free seat or telling the model to ask the person, never a code.

`R-DEB-6` Handover is manual: a statement is placed in the other seat's prompt pane and **MUST NOT**
be sent for the person. Anything the person adds or changes before sending is attributed with a
`> Moderator:` line, and each seat's briefing tells it to comply with such lines.

`R-DEB-7` The first seat opens. Each briefing requires a debater to name itself in the first sentence
of every statement, so a listener — or a muted observer reading the highlight — always knows who is
speaking. Both seats speak in the Mac's standard voice unless the person chooses otherwise — picking
for them sorts straight into the novelty voices — and are separated instead by a small pitch and rate
difference.

`R-DEB-8` Each seat's window carries a debate bar showing the motion, the seat, the statement count,
what it is waiting for, and the moderator's **Skip turn** and **End debate**. Ending one seat ends
the other exactly once, and a finished room's id stops working immediately.

`R-DEB-10` Each seat's bar carries an **Auto** switch, off by default and per seat: while it is on,
a statement arriving in that window is passed to its debater without waiting for Send, and switching
it on passes along a statement already waiting. One side may run automatically while the other is
still moderated by hand. The rule belongs to the debate, not to the window: the machine holds the
per-seat setting and answers it in the `deliver` effect, so it is decided and tested in one place.

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
| **B5** | ~~Contextual-phrase API for `SpeechTranscriber`~~ | **Resolved.** `AnalysisContext.contextualStrings` confirmed against the macOS 26 SDK; `R-STT-19` binds to it directly and `R-STT-21` is retired. See [§8.6](#86-custom-vocabulary). |
| **B6** | Streaming responses | The model's reply arrives whole. Token-by-token display and speech would need a `turn.append` VCP method and re-segmentation mid-playback. |
| **B7** | Barge-in | Excluded by decision (conflict **C1**). Reversible: it would need acoustic echo cancellation plus the echo guard described in that discussion. |
| **B8** | Localisation | UI strings are `String(localized:)` from the start; only `en` ships. Command matching is English-only and tied to `Commands and Dictation.md`. |

---

## Appendix C — Original specification (v1.0)

Preserved verbatim. This project is not under version control, so the superseded text is kept here
rather than lost. Every statement in it is traced to a requirement in
[Appendix D](#appendix-d--traceability-to-v10).

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

Every statement in [Appendix C](#appendix-c--original-specification-v10) maps to at least one
requirement here. Nothing from v1.0 was dropped.

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
