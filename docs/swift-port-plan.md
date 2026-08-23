# Swift port plan — OpenMausBot harness → native macOS app

**Decision being planned for:** a full port of the Node.js harness (`server/`, plus the
macOS-relevant parts of `electron/`) into a native SwiftUI macOS app that embeds the harness
logic **in-process** — no Electron, no Node runtime, no child harness server. The existing
HTTP/SSE API survives only as an *adapter* so today's iOS companion keeps working unchanged.

**Already done:** `server/contracts.ts` (356 lines — the driver SPI + canonical `RuntimeEvent`
union) is ported to [`swift/HarnessCore/`](../swift/HarnessCore/) (1,136 lines across
`Contracts.swift` 206, `RuntimeEvent.swift` 406, `Drivers.swift` 416, `JSONValue.swift` 108).
Nothing below plans around re-porting it; everything builds on top of it.

**Ground rules**

- Source of truth for what lives where: `CONTRIBUTING.md` §Repo map (lines 60–73). Data lives
  in `~/.openmausbot/` (bots, transcripts, per-thread NDJSON event logs, `config.json`,
  `messages.db`). A port goal worth stating up front: **the Swift app reads and writes the same
  data directory, byte-compatible** (`config.json` shape, `messages.db` schema, NDJSON logs),
  so either build can be launched against the same home during the transition.
- All line counts below are `wc -l` on non-test sources unless marked otherwise.
- House rules inherited from `CONTRIBUTING.md`: never build command strings for a shell;
  secrets stay write-only; unknown driver configs downgrade to shadow instances instead of
  crashing (`harness/registry.ts:60-106`); a failed spawn is a failed turn, never a hang.

---

## 1. Inventory

### 1.1 Server subsystems (`server/` ≈ 28,190 non-test LoC; +20,659 test LoC)

| Subsystem | Files | ~LoC | What it does | Key deps | Swift-side strategy |
|---|---|---|---|---|---|
| **Contracts (SPI + events)** | `server/contracts.ts` | 356 | Driver SPI, canonical event union, ID generators | — | **Done** — `swift/HarnessCore` |
| **Config + data dirs** | `server/config.ts` | 423 | Loads/saves `~/.openmausbot/config.json` (zod-validated), env-fallback for secrets, credential-env injection per driver (`injectedEnvironment`, `WORKSPACE_CREDENTIAL_ENV`), default fleet definition | `fs`, `os`, zod | `FileManager` + `Codable` with manual merge-patch semantics (saveConfig merges sections); env injection becomes an `[String:String]` builder passed to spawns; zod → hand-rolled decoding with typed errors |
| **Atomic writes / JSON utils** | `atomic.ts`, `schema.ts`, `redact.ts`, `names.ts` | 38 / 19 / 99 / 25 | temp-file+rename writes, tiny JSON helpers, secret scrubbing for logs | `fs` | `Data.write(to:options:.atomic)`; `redactSecrets` is pure string work — near-literal port |
| **CLI discovery / PATH augmentation** | `env-path.ts` | 342 | Finder-launched apps get a bare PATH; scans `~/.local/bin`, `/opt/homebrew/bin`, nvm/volta/asdf dirs, probes login-shell rc PATH | `child_process.execFile`, `fs` | Direct port — this problem gets *worse* in a GUI SwiftUI app, not better; `Process` environment builder + async login-shell probe |
| **Process spawn substrate** | `procs.ts` | 120 | `spawnCli` (detached, own process group), `execCli`, `killCliTree` (`kill(-pid)`), `describeSpawnFailure` (ENOENT/EACCES → "setup" UX), per-turn broker socket path (unix socket / named pipe) | `node:child_process`, POSIX signals | `Process` + `Pipe` trio; `setsid`-equivalent via `POSIXSPAWN_SETSID` attr or spawning through a tiny helper; `kill(-pid)` → `killpg(pid, SIGTERM)` via Darwin; win32 branches die entirely |
| **Message DB** | `message-db.ts` | 246 | SQLite transcripts (`messages.db`, WAL, `synchronous=NORMAL`); delta INSERT/UPDATE; lazy legacy JSON import | `node:sqlite` (`DatabaseSync`) | SQLite3 C module shim (no GRDB dependency needed): same DDL (`message-db.ts:37-53`), prepared statements, WAL pragmas; ~250 LoC custom wrapper |
| **Store (fleet state)** | `store.ts` | 1,063 | Bots, groups/rooms, tasks, per-thread resume-cursor maps, message folding cache, reactions, unread/read state; change callbacks the SSE layer tees | in-memory + message-db | Actor-backed store; `ChangeCallback` fan-out becomes `AsyncStream` subscriptions; largest pure-logic port in stage 2 |
| **Registry** | `harness/registry.ts` | 197 | configs → live instances; unknown driver/decode failure → **unavailable shadow snapshot**; `describe()` powers model picker w/ CLI candidate lists | — | Direct actor port; shadow semantics are contractual (do not "fix" them) |
| **Event bus** | `harness/bus.ts` | 63 | Fan-in of all adapters' events; stamps `providerInstanceId`; drops cross-driver events; tees redacted canonical NDJSON per thread; delivers to subscribers | `fs.appendFile` | `AsyncStream<RuntimeEvent>` multiplexer + serial `FileHandle` appender; subscriber set with backpressure-free broadcast |
| **Native protocol tee** | `drivers/native.ts` | 26 | Verbatim provider messages to `native/<threadId>.ndjson` for protocol-drift debugging | `fs` | Same, via the bus' file writer |
| **Claude driver** | `drivers/claude.ts` | 971 | Per-turn `claude` process, stream-json over stdio, `--resume <sessionId>` cursor, model catalog from `~/.claude/settings.json`, **per-turn permission broker** (net server on unix socket) | `child_process`, `net` (unix socket), `crypto`, `fs` | `Process` + NDJSON line parsing (`AsyncSequence` over `FileHandle.bytes`); broker → `NWListener`/`NWConnection` over unix domain socket (Network.framework); Keychain untouched (CLI owns its creds) |
| **Codex driver** | `drivers/codex.ts` + `codex-catalog.ts` | 601 + 439 | `codex` app-server JSON-RPC-over-stdio; approvals arrive as in-process RPC requests (no socket); thread-id resume cursor | `child_process` | Same Process substrate; JSON-RPC framing via Codable; MCP servers mounted through argv `-c` flags (port verbatim) |
| **ACP driver family** | `drivers/acp/core.ts` + grok/gemini/kimi/droid/cursor/qwen/hermes/opencode-go | 758 + 2,062 | One JSON-RPC-2.0-over-stdio session runtime (Agent Client Protocol) shared by 8 CLIs; replay gating on `_meta.isReplay`; fail-closed permission options | `child_process` | Port `core.ts` once (L), then each support struct is small (S each) — this is the highest leverage-per-line module in `drivers/` |
| **Antigravity / Pi drivers** | `drivers/antigravity.ts`, `drivers/pi.ts` | 461 / 578 | `agy --print` one-shot stream-json (`--conversation <id>` cursor); pi's own JSON-RPC mode (`sessionFile` cursor) | `child_process`, `fs` | Standard driver recipe; no broker (agy has none — auto-deny semantics documented in header) |
| **API-key drivers** | `drivers/grok.ts`, `drivers/openai-compat.ts` | 227 / 361 | Chat-completions + SSE streaming; transcript-replay model (history handed in each turn); `generateText` for titles | HTTPS client | `URLSession.bytes` SSE parsing; simplest drivers — good early smoke targets |
| **Box agent driver** | `drivers/boxagent.ts` | 273 | Turn runs ON the cloud box via Box REST prompt/poll API | HTTPS polling | `URLSession` + `Task.sleep` poll loop |
| **Local-model inject** | `drivers/local-inject.ts` | 422 | Probes Ollama/oMLX/LM Studio/etc., `host::model` ids decoded/injected per driver | `fs`, `net` probes | URLSession health probes + catalog merge; near-literal port |
| **Peer-agent comms proxy** | `drivers/agents-proxy.ts` | 180 | MCP stdio proxy (list_bots/ask_bot) routed back through harness `/api/internal/*` with per-boot token | `child_process`, HTTP | In-process this becomes a **direct function call** into the comms dispatcher — no HTTP hop needed internally; keep token-guarded HTTP only under the iOS adapter |
| **Phone / dweb proxies** | `drivers/phone-proxy.ts`, `drivers/dweb-proxy.ts` | 358 / 196 | MCP stdio proxies for Android-over-adb and the dweb daemon | `child_process`, HTTP | Same in-process conversion where the consumer is the harness itself |
| **Turn context building** | `turn-context.ts` | 68 | Replay/fresh/rewind preambles; `engineIsFresh` cursor heuristics | pure | Pure functions — literal port, easy unit tests |
| **Turn watchdog** | `turn-watchdog.ts` | 96 | Activity-based stall detector; turns parked on humans exempt | `setInterval` | `Task` + `ContinuousClock` sweep loop (no unref semantics needed in-process) |
| **Steer queue / delegations** | `steer-queue.ts`, `delegations.ts` | 108 / 296 | Mid-turn message queue drained on settle; async peer handoff after turn completes; depth cap | memory | Actor queues; drain hooks fire from the fold |
| **Rooms / member turns** | `member-turn.ts`, `room-turn-timeout.ts`, `room-cwd.ts`, `comms-visibility.ts`, `chief-of-staff.ts` | 15 / 35 / 18 / 112 / 62 | Group-thread responder selection, timeouts, channel mirroring, coordination prompts | pure + store | Literal ports |
| **Approval machinery** | `auto-approve.ts`, `peer-approval.ts`, `peer-approval-key.ts`, `decision-log.ts`, `computer-control.ts`, `control-client.ts` | 175 / 206 / 6 / 141 / 135 / 127 | Auto-mode guard ("you probably didn't mean rm"), peer ask approval gate, narrow always-allow keys, append-only authorization audit NDJSON, who-is-driving hold state | memory + `fs` | Ports are straightforward; the *timing* risk lives in the claude broker (§3.3) |
| **Repeat detector** | `repeat-detector.ts` | 49 | Unattended-loop circuit breaker on repeated tool calls | pure | Literal port |
| **Attachments / avatars** | `attachments.ts`, `avatar-image.ts`, `bot-profile.ts`, `bot-cwd.ts`, `shared/bot-avatar.ts` | 94 / 169 / 87 / 26 / 46 | Image save-by-path for CLIs, OpenAI image-gen avatar pipeline, profile validation, cwd sandboxing | `fs`, HTTPS | `FileManager` + URLSession; avatar gen hits OpenAI images API |
| **Workspace + memory** | `workspace.ts` | 172 | Per-bot working dirs under `~/.openmausbot/workspaces/<botId>` + MEMORY.md budget loading | `fs` | Literal port |
| **Skill library** | `skill-library.ts` | 99 | Loads bundled skills dir, renders instructions into system prompts | `fs` | Bundle skills as Swift Package resources |
| **Team / scout / directory** | `project-scout.ts`, `team-library.ts`, `team-manifest.ts`, `bot-directory.ts` | 371 / 194 / 306 / 150 | GitHub/library team import-export, project scouting, bot discovery directory | HTTPS, `fs` | URLSession ports |
| **Routines** | `routines.ts` | 576 | Cron-ish scheduler (`once`/`daily`+weekdays), run receipts, missed-run detection, emits keyed frames onto SSE bus | `fs`, timers | TimerFoundation `Timer` or Task-sleep scheduler; persistence file shape preserved |
| **Webhooks** | `webhooks.ts`, `webhook-ingress.ts` | 633 / 177 | Trigger registry (secret-hash storage, capture-one-verified-request flow, delivery dedupe) + **second HTTP listener** (`:8799+1`) accepting POSTs at `/hooks/wh_*` | `http`, `crypto` | `NWListener` TCP server + minimal HTTP/1.1 request parser (~200 LoC — the ingress handler is deliberately tiny, see §3.4) |
| **Cloud/VM computers** | `container-computer.ts`, `computer-proxy.ts`, `vps-computer.ts`, `local-computer.ts`, `remote-computer.ts`, `computer-observation.ts`, `mcp-bridge.ts`, `container-mcp.ts`, `vps-container-mcp.ts`, `local-vm-idle.ts`, `local-vm-lease.ts`, `local-routing.ts` | 1,131 / 1,073 / 808 / 346 / 149 / 159 / 298 / 30 / 33 / 45 / 71 / 15 | Docker/Podman Local-VM lifecycle + leases + idle reaper; the MCP stdio computer-proxy giving CLIs act+capture tools over Box REST; BYO-VPS over SSH exec; byte-transparent MCP bridge with who-is-driving gate and liveness probe; Cua connection descriptor reading/validation | `child_process`, `docker` CLI, HTTPS, `net` | Largest single cluster (≈4.2k LoC). `Process` for docker/ssh; URLSession for Box API; the MCP proxies become in-process tool providers for drivers that support it — but note CLIs spawn them as *separate processes*, so they must remain standalone executables shipped inside the .app bundle (see §3.1) |
| **Composio connector** | `composio.ts` | 765 | Sessions API: connect/link toolkit accounts, MCP endpoint minting, connector-card state machine | HTTPS, zod | URLSession + Codable; card states ride the store |
| **TTS** | `tts/index.ts`, `tts/elevenlabs.ts`, `tts/speech-text.ts` | 63 / 104 / 219 | ElevenLabs synth + utterance planning from activity chips | HTTPS | URLSession + `AVAudioPlayer`; macOS-native alternative (AVSpeechSynthesizer) possible later |
| **HTTP + SSE server** | `index.ts` | 4,433 | Everything above wired together: ~90 raw `node:http` routes (`index.ts:2414-4395`), static UI serving, SSE stream with `<streamId>:<seq>` cursors + 500-frame replay buffer (`index.ts:396-432`, `2727-2774`), server-side event folding (RuntimeEvents → transcript messages/cards), internal comms endpoints, boot wiring | `node:http`, `zod` | **Does not port 1:1.** Split three ways: (a) fold + orchestration logic → in-process `HarnessController` (this is the real port), (b) REST+SSE → thin adapter re-hosted on `NWListener` for iOS (§4), (c) static-file/MIME serving → deleted |

### 1.2 Electron pieces that matter for a macOS-native replacement (≈4.9k non-test LoC)

| File | ~LoC | Responsibility | Swift replacement |
|---|---|---|---|
| `electron/main.mjs` | 1,007 | Window mgmt, **single-instance lock**, harness fork via `utilityProcess.fork` (`main.mjs:272-320`) with identity-checked port probing, `safeStorage` credential encryption (`credentials.bin`) + plaintext config migration sweeps, IPC surface (`main.mjs:637-830`: screen frames, terminal launch, folder pick, diagnostics, external links, perm status/mic, speech start/stop, companion lifecycle, credential:set) | SwiftUI App lifecycle; `NSApplication` delegate for single-instance (or `NSDistributedNotificationCenter`); **Keychain** replaces safeStorage; most IPC handlers become direct function calls — they existed only because renderer and main were separate processes |
| `electron/cua.mjs` (+ `cua-connection.cjs`, `cua-linux*.cjs`) | 339 + cjs | Cua computer-use daemon: **embedded host** (packaged: private daemon spawned so TCC grants attribute to `com.openmausbot.app`) vs standalone attach; writes `<userData>/cua-connection.json` descriptor the harness reads (`local-computer.ts:60-77` validates file identity) | Direct port of the darwin branch: spawn/embedded host via `Process`, XPC-style supervision, same descriptor file so drivers don't change; entire Linux runtime staging tree dies |
| `electron/speech.mjs` (+ `build-speech-helper.mjs`) | 200 + 66 | Dictation via a separately-built **Swift speech-helper .app** because Speech/AVFoundation needs its own Info.plist identity under Electron | Big native win: the SwiftUI app **is** the Info.plist identity — `SFSpeechRecognizer`/`AVAudioEngine` runs in-process; helper-app build/lifecycle code deleted |
| `electron/screen-preview.cjs` + `desktopCapturer` usage | cjs | Screen capture guard/source selection for live computer view | `ScreenCaptureKit` (`SCStream`) in-process |
| `electron/workspace-credentials.mjs` | 70 | Boot migration of plaintext keys into encrypted store; env hand-off to harness at spawn (`main.mjs:286-295`) | Keychain read at boot directly into the config loader's env-fallback map; no spawn boundary to cross anymore |
| `electron/updater.mjs` + `updater-coordinator.mjs` | 85 + 145 | electron-updater lifecycle | Sparkle 2 |
| `electron/single-instance.mjs` | 16 | Second-launch activation | `NSApplicationDelegate.applicationShouldHandleReopen` |
| `electron/terminal-launch.mjs` | 46 | Opens Terminal/iTerm at a path (install sign-ins) | `NSWorkspace.open(URL(fileURLWithPath:))` + AppleScript for iTerm |
| `electron/diagnostics.mjs` | 150 | Log-tail diagnostics report | Literal port (reads same logs) |
| `electron/android-device.mjs` | 247 | Physical Android phone frame/input over adb | Keep only if the feature survives the port; `Process(adb)` either way |
| `electron/companion.mjs` + `companion-entry.mjs` | 282 + 27 | Spawns/supervises the Node companion sidecar (:8810 device-facing, :8811 control) | During transition: spawn the *existing* sidecar binary exactly as today (it only needs loopback harness access). Later: port sidecar into-process as the iOS adapter (stage M7) |
| `electron/preload.cjs`, `capabilities.cjs`, `desktop-viewer.cjs` | cjs | Renderer bridge, capability contract, viewer-window origin checks | Die — capability checks become compile-time/native checks in the app |

### 1.3 Companion sidecar (Node, stays initially)

`companion/src/` ≈ 2,727 LoC (`mdns.ts` 700, `proxy.ts` 381, `control.ts` 371, `devices.ts`
303, `index.ts` 274, `listener.ts` 182, `routes.ts` 181, `wire.ts` 145, `advertise-watch.ts`
102, `state.ts` 88). It authenticates paired devices, default-denies routes, scrubs responses,
and forwards to the harness over loopback. Because it speaks plain HTTP to the harness, it
keeps working against the Swift app's adapter **unchanged** — which is why the iOS-compatible
surface is staged late (M7) rather than first.

---

## 2. Dependency-ordered port stages

```
M0 contracts ✅
   └─► S1 foundation (config, paths, procs, atomic/redact)
          └─► S2 persistence (SQLite shim, Store)
                 └─► S3 bus + registry
                        └─► S4 first driver + fold  ── first usable thing
                               └─► S5 app shell MVP (SwiftUI, in-process calls)
                                      ├─► S6 driver fleet (ACP core unlocks 8 engines)
                                      ├─► S7 approval machinery (broker, auto-mode, audit)
                                      ├─► S8 fleet features (rooms, steer, delegations, comms)
                                      ├─► S9 computers (box/VM/VPS + proxies)
                                      ├─► S10 integrations (routines, webhooks, composio, tts, teams…)
                                      ├─► S11 iOS adapter (REST+SSE subset, pairing)
                                      └─► S12 desktop parity (TCC, speech, capture, Cua, updater)
```

| Stage | Contents (files) | Size | Blocks usability? |
|---|---|---|---|
| **S0** | `contracts.ts` → `swift/HarnessCore` | ✅ done | — |
| **S1 Foundation** | `config.ts`(423), `env-path.ts`(342), `procs.ts`(120), `atomic/schema/redact/names`(181), data-dir bootstrap + legacy `.openglobot` rename (`config.ts:144-161`) | **M** | Yes — everything imports it. Env-injection maps replace zod/env juggling; `augmentedPath()` must exist before any spawn works |
| **S2 Persistence** | `message-db.ts`(246) via SQLite3 C shim, `store.ts`(1,063) | **M** | Yes — bots/transcripts/cursors. Schema + WAL pragmas byte-compatible with `message-db.ts:25-55` |
| **S3 Harness core** | `harness/bus.ts`(63), `harness/registry.ts`(197), `drivers/native.ts`(26) | **S** | Yes — drivers are untestable without bus+registry. Shadow-downgrade semantics mandatory |
| **S4 First driver + fold** | `drivers/claude.ts`(971) minus broker, `turn-context.ts`(68), `turn-watchdog.ts`(96), the RuntimeEvent→transcript **fold** currently living in `index.ts:434-1100` (must be excavated, not rewritten) | **L** | Yes — this is the product. Fold extraction is the subtlest work in the whole port (keyed item/request maps, card lifecycle, `answerRequest` ordering at `index.ts:448-514`) |
| **S5 App shell MVP** | SwiftUI app embedding S1-S4; internal calls replace REST for the UI; NDJSON logs land in `~/.openmausbot` | **L** | Unblocks all parallel tracks; app is *usable* here |
| **S6 Driver fleet** | `acp/core.ts`(758) then 8 supports (2,062), `codex.ts`+catalog(1,040), `pi.ts`(578), `antigravity.ts`(461), `grok.ts`(227), `openai-compat.ts`(361), `boxagent.ts`(273), `local-inject.ts`(422) | **L** aggregate (each S/M after core) | No — additive |
| **S7 Approvals** | Claude broker (inside `claude.ts:186-330` region), `permission-proxy` entry, `auto-approve.ts`(175), `peer-approval.ts`(206)+key, `decision-log.ts`(141), always-allow keying in store | **M** | Blocks *real* use of claude beyond acceptEdits; codex/ACP approvals are simpler in-band paths |
| **S8 Fleet features** | rooms (`member-turn`,`room-*`,`comms-visibility`,`chief-of-staff` ≈240), `steer-queue.ts`(108), `delegations.ts`(296), `repeat-detector.ts`(49), `agents-proxy` in-process(180) | **M** | No |
| **S9 Computers** | `container-computer.ts`(1,131), `computer-proxy.ts`(1,073), `vps-computer.ts`(808), `local-computer.ts`(346) + satellites (≈700), `mcp-bridge.ts`(298); ship proxies as bundled executables | **L** | No (feature-gating fine) |
| **S10 Integrations** | `routines.ts`(576), `webhooks.ts`+ingress(810), `composio.ts`(765), tts(386), `avatar-image.ts`(169), attachments/profile/cwd(207), workspace(172), skill-library(99), team/scout/directory(1,021) | **L** aggregate | No |
| **S11 iOS adapter** | Re-host allowlisted REST + resumable SSE on `NWListener`; port `companion/src/routes.ts` semantics or keep Node sidecar; pairing/device registry (`devices.json`) | **M** | Only blocks the phone, not the Mac |
| **S12 Desktop parity** | TCC prompts (mic/speech/accessibility/screen), `SFSpeechRecognizer` in-process, ScreenCaptureKit preview, Cua embedded host (`cua.mjs` darwin path), Keychain migration from `credentials.bin`, Sparkle, diagnostics | **L** | Blocks shipping as a real .app, not development |

Critical-ordering notes: config before registry (registry loads `instanceConfigs()`);
bus before any driver (adapters emit through it); fold before the UI makes sense; the ACP core
before the eight ACP engines; `env-path`/`procs` before literally any CLI driver runs.

---

## 3. The five riskiest parts

### 3.1 PTY-less child-process management of provider CLIs
Every engine is driven as a **headless child with piped stdio** — no PTY anywhere
(`procs.ts:26-52` spawns detached with its own process group precisely so `kill(-pid)`
reaps the CLI *and* the MCP proxies it spawned). The Swift port must reproduce four
unglamorous behaviors: (1) process-group teardown — Darwin has `killpg`, but `Process` does
not expose setsid directly, so the port needs a posix_spawn attribute path or a tiny helper,
and getting it wrong strands orphaned MCP children holding sockets/screenshots; (2) the
stdin-write race handling (`procs.ts:39-51` swallows async EPIPE so one dead pipe can't
crash the harness — Swift's `FileHandle.write` failure semantics differ and must be made
equally boring); (3) NDJSON framing over stdout with partial-line buffering (Node's readline
is replaced by `bytes.lines`, but the fake-CLI contract suite — `testing/fake-claude-cli.ts`
192, `fake-acp-cli.ts` 463, `fake-codex-app-server.ts` 175 — must be rebuilt as scripted
Swift executables or the entire regression net for argv/env hygiene, interrupts, and
failure modes silently disappears); (4) spawn-failure translation (`describeSpawnFailure`)
because "ENOENT" is the single most common user-facing error and the setup-vs-retry UX hangs
on it. Risk: high frequency, medium severity — every driver touches this daily.

### 3.2 SSE resume cursors and the honest-gap replay protocol
The stream protocol is small but load-bearing for the iOS companion: every broadcast gets
`id: <streamId>:<seq>`, a 500-frame ring buffer holds replays, **screen frames consume seq
slots but are never buffered** (`index.ts:415-432`), and the `hello` frame answers `?since=`/
`Last-Event-ID` with a boolean that must lie about nothing — a cursor that fell off the end
returns `resumed:false` forcing a cold hydrate rather than a hole (`index.ts:2736-2761`).
The phone's fold commits its cursor only after verified recovery (`docs/ios-companion.md`
"Stream and state model"); any deviation — renumbered seqs, buffered screens, a hello that
claims a gap was replayed — corrupts client state in ways that look like lost messages, the
worst possible bug class for a chat app. The adapter must be byte-exact on frame format and
semantics, and validated against the captured fixtures (`scripts/capture-companion-fixtures.mjs`)
plus the existing `CompanionCoreTests`. Risk: low frequency, very high severity, and it's the
one piece whose correctness is defined by a client we don't ship in this repo.

### 3.3 Permission-broker timing and approval-state truthfulness
The Claude path asks through a **per-turn unix-socket broker**: the CLI's spawned
`permission-proxy` forwards each ask to the in-harness server and blocks; unanswered
permissions deny-with-guidance after a timeout, unanswered questions get "use your best
judgment," duplicates are skipped, in-flight asks are drained with system replies when the
turn closes, and an ask landing on a closed broker still gets a truthful answer
(`claude.ts:186-215` and the broker body). On top sits the human-answer path, which must
snapshot the card *before* awaiting the adapter because resolution consumes its own map
entry synchronously (`index.ts:455-466`), records an audit row only when the verdict actually
reached the engine (`outcome !== "unavailable"`, `index.ts:482-493`), and fail-closes to
"the action never ran." This is a lattice of timeouts × close-races × id collisions that took
real bug fixes to get right (see `docs/plans/2026-08-18-001-fix-permission-broker-ask-id-collision-plan.md`
and `-teardown-zombie-cards-`). Swift's actor model changes where awaits yield, so every
race window shifts even if the logic ports line-for-line. Add auto-approve guards, narrow
always-allow grants, and the peer-approval gate, and this is the port's highest-severity
correctness surface: a mistake here doesn't drop a message, it runs or blocks an action the
user didn't sanction.

### 3.4 The webhook receiver and scheduled-trigger surface
Webhooks are the only place the Swift app must accept connections from **the open
internet**: a second listener on `:8799+1` (`index.ts:114`), secret-in-path-or-bearer auth
with hashed storage and constant-time compare (`webhooks.ts:1-9` imports carry the discipline),
reject-before-buffering of bad capability URLs (`webhook-ingress.ts:109-117`), a 256 KB body
cap, capture-one-authenticated-request verification for new hooks, delivery-ID dedupe, and
event-type allowlists. The Node implementation leans on `http.createServer` for parsing
robustness (chunked encoding, header edge cases, slowloris tolerance); a hand-rolled
`NWListener` + HTTP parser must match that hardening or become the app's remote attack
surface. Routines compound it: schedule evaluation, missed-run detection on wake-from-sleep
(App Nap and `Task.sleep` drift differ from a long-lived Node timer), and webhook-fired runs
that enqueue turns with receipts. Risk: medium likelihood, high severity — security-sensitive,
network-facing, and dependent on platform timer semantics nobody unit-tests until 3am.

### 3.5 TCC / desktop-integration parity
Today the Electron main process owns every OS-touched capability: `safeStorage`-encrypted
credentials, `desktopCapturer` screen preview, mic permission, dictation via a separately
signed speech-helper bundle (`speech.mjs:1-36` — the comment explains macOS requires the
calling code to carry its own Info.plist identity), the Cua **embedded** daemon so screen/
accessibility TCC grants attribute to `com.openmausbot.app` (`cua.mjs:1-15`), terminal
launching, and single-instance enforcement. Going native flips several of these from
"solved by someone else's framework" to "ours": the SwiftUI app *can* run Speech in-process
(deleting the helper app — genuine win), but it must now own its entitlements, hardened-runtime
signing, notarization, the exact TCC prompt choreography (mic + speech + screen recording +
accessibility, each with first-run explanation copy), ScreenCaptureKit stream management,
Keychain migration of `credentials.bin` contents without ever displaying secrets, and a
Sparkle update channel with the same "never auto-update mid-turn" caution the updater
coordinator encodes. The Cua embedded-host handoff (private daemon, socket path, descriptor
file the harness revalidates by file identity at `local-computer.ts:60-77`) must keep working
under a new host binary identity or local computer-use silently downgrades. Risk: guaranteed
work of high complexity, mostly at M12, and the classic cause of "works in dev, prompts
forever in the packaged build."

---

## 4. What we deliberately do NOT port

Dies outright when the harness moves in-process behind SwiftUI:

- **The Vite dev proxy and static-serving half of the server.** `vite.config.ts:41-45`
  exists only to forward browser `/api` calls; `index.ts:116-125` (MIME table) and the
  `STATIC_DIR` branch (`index.ts:4395`) exist only to serve built React assets. A native app
  has neither concern.
- **The process boundary itself.** `utilityProcess.fork` + port-probe-with-identity-check
  (`main.mjs:272-320`), `ELECTRON_RUN_AS_NODE=1` for spawned proxies (`claude.ts:182-184`),
  the COMMS_TOKEN bearer dance for loopback `/api/internal/*` (`index.ts:137-148`) — the
  agents-proxy becomes a direct function call; tokens survive only at the iOS adapter edge.
- **Build/packaging machinery for the JS harness:** `dist-server/`, `bundle-server.mjs`,
  `pnpm build:server`, `tsconfig.server.*`.
- **All non-macOS branches:** win32 named pipes/taskkill/`.cmd` shim resolution
  (`procs.ts:84-119`, `env-path.ts:58-73`), the Linux CUA runtime/AppImage staging tree
  (`cua-linux*.cjs`, `scripts/cua-linux-release.mjs`), GNOME/Wayland gates
  (`CONTRIBUTING.md:120-132`). This alone removes roughly a quarter of the audited surface.
- **The React renderer (`src/`)** — replaced by SwiftUI views (out of scope for this doc,
  but it means `preload.cjs`/IPC bridges and the desktop-capability indirection go too).
- **node:sqlite dependency question** — replaced by the SQLite3 C module; conversely the
  *legacy JSON thread import* stays read-only-compatible but no new JSON threads are written.

**Must survive as the iOS adapter** — the exact allowlist from `companion/src/routes.ts:53-119`
(default-deny; anything absent stays unreachable), which pins the REST/SSE surface:

- `GET /api/config` (configured-booleans only), `GET /api/events` (resumable SSE),
  `GET /api/instances`
- Fleet + composition: `GET/POST /api/bots`, `POST /api/bots/:id/{messages,interrupt,read,always-allow}`,
  `POST /api/bots/:id/messages/:mid/{edit}`, `active-branch`, `tasks[/tid]` CRUD,
  `PATCH profile` (paired-safe subset), `POST avatar/generate`, `POST /api/bots/:id/computer/join`
  (capability-gated cloud desktop)
- Rooms: `POST /api/groups`, `POST /api/groups/:id/{messages,read}`
- Threads: `GET messages` (paged), `GET messages/:mid/image`, `POST reactions`,
  `GET export`, `POST respond`, `GET /api/search`
- Attachments: `POST /api/attachments`, `GET /api/attachments/:file.(png|jpe?g|gif|webp)`
- Voice: `GET /api/tts/voices`, `POST /api/tts/speak`
- Routines (read/run/create/edit/delete) and connector read/authorize routes
- Plus pre-auth specials: `POST /api/pair` and `GET /api/health` (`routes.ts:157-164`)

Everything else (webhook management, local-VM lifecycle, internal comms, config writes,
device revocation) stays Mac-only by design — the refusal copy in `routes.ts:128-149` should
be carried over verbatim.

---

## 5. Milestone ladder

Each milestone ends in something demonstrable; no milestone merges without its demo running.

| Milestone | Slice contents | The demo |
|---|---|---|
| **M0 — Contracts** ✅ | `swift/HarnessCore` (1,136 LoC): SPI, RuntimeEvent union, JSONValue | `swift build && swift test` green |
| **M1 — It spawns a CLI** | S1+S3+S4-minus-fold: config dirs, `augmentedPath`, `Process` substrate, bus, registry, claude driver headless turn, NDJSON tee | `swift run ombctl "summarize this repo"` prints streaming `content.delta` events from the real `claude` CLI, with `events/<thread>.ndjson` written to `~/.openmausbot` |
| **M2 — A chat that survives restart** | S2 + fold extraction + turn-context/watchdog: SQLite shim, Store, event folding, resume cursors | Minimal SwiftUI window: send a message, watch the reply fold into a transcript, **quit the app, reopen** — history loads from `messages.db` and the next turn resumes the Claude session via `--resume` |
| **M3 — It asks permission** | Broker on unix socket, proxy executable bundled in the .app, cards, always-allow, decision log | Bot tries to run a shell command outside acceptEdits → approval card appears in-app → Allow executes, Deny returns the skip-note; decision lands in `decisions.ndjson`; "Always allow Bash:git" sticks for the next turn |
| **M4 — The fleet** | Registry `describe()` + model picker, codex + ACP core + 2 ACP engines, rooms, interrupt, steer queue | Two bots (claude + one ACP engine) in a shared room responding to @mentions; interrupt stops a running turn mid-stream; steering delivers a mid-turn message that the reply acknowledges |
| **M5 — It has hands** | Box agent + computer-proxy executables, Local VM (container-computer + leases), VPS, who-is-driving | Create a bot with a cloud computer, ask it to screenshot and click something; press "take the wheel" mid-turn — the bot's next action refuses while held, resumes after hand-back |
| **M6 — It wakes up on its own** | Routines scheduler, webhook receiver + triggers, composio connectors | Register a GitHub webhook → push a commit → a routine-run receipt appears in chat with the bot acting on the payload; a daily routine fires on schedule and shows `missed` correctly after sleep |
| **M7 — The phone still works** | REST+SSE adapter on `NWListener` implementing the `routes.ts` allowlist byte-compatibly; pairing/device registry ported or Node sidecar retained against the new backend | Launch today's **iOS companion unchanged**, pair by QR, page transcripts, approve a permission card from the couch; captured fixture tests pass against the Swift server |
| **M8 — A real Mac citizen** | TCC choreography, in-process `SFSpeechRecognizer` dictation, ScreenCaptureKit preview, Cua embedded host under the new bundle id, Keychain migration, Sparkle, diagnostics | Signed, notarized `.app`: dictate a prompt by voice, grant screen-recording once, drive the user's actual desktop through Cua with TCC attributing to the new app, update via Sparkle |

**Verification spine throughout:** port the fake-CLI contract suite to scripted executables
driven by Swift Testing as part of M1-M4 (argv/env hygiene, interrupts, permission flows),
and keep `recordEvents(...).until(...)`'s no-sleeps discipline — the CONTRIBUTING.md house
rule (`CONTRIBUTING.md:89-96`) is a testing architecture, not a Node detail. From M7 onward,
the companion fixture capture script doubles as the cross-implementation conformance harness.

---

*Sources: all paths and counts measured in this repo on 2026-08-23; `wc -l` totals —
`server/` 28,190 non-test / 20,659 test, `electron/` 4,897 non-test, `companion/src/` 2,727.*
