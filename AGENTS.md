# AGENTS.md

OpenMausBot is a local-first desktop chat app for running a team of AI agents. It is a pnpm
workspace monorepo: a React UI (`src/`) + an Electron shell (`electron/`) talk over HTTP/SSE to a
portable Node "harness" server (`server/`). See `CONTRIBUTING.md` and `README.md` for the
authoritative dev-setup, repo map, and command list.

## Cursor Cloud specific instructions

### Node version (important)
- The project requires **Node 24+** (`engines.node >=24`): the server runs TypeScript directly via
  `node --experimental-strip-types` and uses the built-in `node:sqlite` (needs Node ≥ 23.4). Node 22
  will not run the server or the tests.
- The cloud VM ships a Node 22 binary at `/exec-daemon/node` that sits early in `PATH`. Setup pins
  Node 24 in two durable ways so it wins in every shell: nvm's `default` alias points at Node 24, and
  Node 24 binaries are symlinked into `/usr/local/cargo/bin` (the first `PATH` entry) plus a prepend
  line in `~/.bashrc`. If a fresh session ever runs Node 22, run `node -v`; if wrong, re-link with
  `for b in node npm npx corepack pnpm; do ln -sf "$HOME/.nvm/versions/node/v24.19.0/bin/$b" /usr/local/cargo/bin/$b; done`.
- The startup update script only runs `pnpm install`; it does not install Node (that persists in the
  environment snapshot).

### Services (run in dev mode; do not use `pnpm build`/packaging for dev)
- **Harness server** — `pnpm dev:server` → `http://127.0.0.1:8799` (also starts a webhook receiver on
  `:8800`). This is the backend; nothing else works without it. Health check: `GET /api/health`.
- **Vite UI** — `pnpm dev` → `http://127.0.0.1:5199`; it proxies `/api` to the harness. Start the
  harness first.
- Run each as a long-lived process (e.g. a tmux terminal), not from `install`.
- **Electron desktop shell** (`pnpm dev:desktop`) needs a display and is optional; the browser UI at
  `:5199` is the primary way to exercise the app headlessly.

### Chatting with a bot requires an agent CLI (external, not available by default)
- Bots run on a local agent CLI (`claude`, `codex`, or `grok`) that must be installed **and
  interactively logged in / API-keyed**. Without one, `GET /api/instances` reports each provider as
  `unavailable` and a bot cannot complete a real turn — but the UI, harness, SSE stream, and the
  SQLite message store all boot and are fully interactive. Do not fake a CLI to fabricate replies.
- App state lives in `~/.openmausbot/` (bots, transcripts, per-thread NDJSON logs, `config.json` with
  keys). A default "Zephyr" bot is created on first run.

### Exercising a real chat turn without a paid CLI (useful for demos/manual tests)
- The built-in **OpenAI-compatible** engine (`openaiCompat` instance, `server/drivers/openai-compat.ts`)
  needs no CLI. Point it at any OpenAI-compatible `/chat/completions` endpoint by starting the harness
  with `OPENAI_COMPAT_URL` and `OPENAI_COMPAT_API_KEY` set (e.g. a free OpenRouter/Groq key, or a local
  stub server). The `openaiCompat` instance then reports `available` in `GET /api/instances`.
- Point a bot at it with `PATCH /api/bots/<id>` body
  `{"modelSelection":{"instanceId":"openaiCompat","model":"<model>"}}`, then
  `POST /api/bots/<id>/messages` `{"text":"..."}`. `startTurn` rejects with 409 (message not persisted)
  if the bot's selected instance is `unavailable`, so an engine must be available first.
- SSE events (`GET /api/events`) stream live through the Vite `/api` proxy (verified token-by-token).
  In an automated/headless browser the chat pane may need a manual refresh to render a live turn even
  though the server pushed the events and persisted the reply — this is a browser-side quirk, not a
  harness/proxy problem.

### Verify / lint / test / build
- CI gates (`.github/workflows/ci.yml`, Node 24): `pnpm typecheck`, `pnpm test`, `pnpm check:electron`,
  and `pnpm exec vite build`. `pnpm check:electron` downloads the Electron binary on first run.
- `pnpm lint` (oxlint) is **not** run in CI and currently reports pre-existing `anti-slop` rule errors
  on a clean `main` checkout — a lint failure there is not caused by your environment.
- `pnpm test` is self-contained: it spawns scripted **fake** provider CLIs (`server/testing/`) and
  points `HOME` at a temp dir, so it never needs a real agent CLI or touches `~/.openmausbot`.
