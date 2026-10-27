# TuttiDash by TranscentIA

Run several AI coding agents in parallel on a Linear backlog, and keep an eye on them from the Mac notch.

![TuttiDash panel with example data](docs/imagens/painel.png)

TuttiDash is the set of local tools that TranscentIA uses to work
through a Linear project with coding agents in parallel **lanes**: one card, one git worktree and one
agent per lane at a time. It is shared as-is, as a working example. It was built for one developer's
Mac and workflow, and it shows. **The app UI and most of the docs are in Brazilian Portuguese.**
[Leia em português](README.pt-BR.md).

## What's inside

| Part | Where | What it does |
|---|---|---|
| Dispatcher | `lanes/dispatcher.py` | Every 60 s it takes a ready card from the Linear project, creates a worktree, runs the agent headless in tmux (Claude Code, Codex, OpenCode, Grok CLI…), runs the project's test command (the *proof*), then pushes, opens the PR with `gh`, comments and moves the card to *In Review*. The agent itself never talks to Linear or GitHub. |
| Watcher | `bots/watch.py` | Reviews PRs, merges when the proof is green, triages stopped or failed lanes and only calls the owner (`needs:dono` label) after the same failure repeats. The AI only reads and returns text (`claude -p`, local model or OpenCode); the script does every action. |
| Notch app | `apps/notch-mac` | SwiftUI/AppKit app in the notch and menu bar: lanes, builds, tests, deliveries, cost from the lane logs, account limits where an official source exists, and the settings. |
| `gasto` CLI | `gasto.py`, `gasto_lanes/` | Cost ledger built from the lane logs, by day, week, card and lane. See [docs/gasto.md](docs/gasto.md). |
| Agent catalog | `agents.d/*.json` | One manifest per agent (CLI, cost type, models per effort, review command). Python and Swift read the same files. |

## Before you use it

- **macOS only** (14 or newer). Personal project: expect rough edges. Issues are welcome; there is no support promise.
- **It runs agents unattended with your accounts.** They edit code, run commands and spend money or quota.
  Try it on a throwaway project first, keep every lane disabled until a dry run looks right, and set
  budgets (`lanes.budget_usd`) and protected paths (`protegidos`).
- **Account limits come only from official or local sources**: the GitHub Copilot billing API and the local
  OpenCode session database. Claude Code, Codex, Grok and Gemini subscriptions have no official public
  quota API, so TuttiDash does not show their limits. The reading engine is pluggable (`FonteUso`, see
  `apps/notch-mac/README.md`).
- **It never renews or rewrites another tool's credentials.** It reads logs, its own state and its own config.
  The Linear API key lives in the macOS Keychain.

## Requirements

- macOS 14+ and Xcode 16+ (Swift toolchain)
- Python 3.9+ (standard library only), git, the [GitHub CLI](https://cli.github.com) (`gh auth login`) and tmux
- The agent CLIs you want to use, already logged in
- A Linear workspace and a personal API key

## Quick start

```bash
git clone https://github.com/francieloliveira/tuttidash.git
cd tuttidash

# 1. Tools into ~/.transcentia, without background jobs yet
tools/install.sh --sem-launchd

# 2. Linear API key in the Keychain (you will be prompted for it)
security add-generic-password -s linear-transcentia-lanes -a "$USER" -w

# 3. The app
cd apps/notch-mac && ./build.sh && open build/TuttiDash.app
```

Then configure, in the app (*Ajustes*) or in `~/Library/Application Support/TuttiDash/config.json`
(start from [`config.example.json`](config.example.json)):

- **`projetos`**: the Linear project id, the repo, the worktrees folder, the proof command
  (`{suite}` is replaced by the suite the agent asked for) and the protected paths.
- **Linear**: states named *Todo*, *In Progress* and *In Review*; labels `needs:dono` (or your
  `linear.owner_label`), `lane:falhou` and `lane:parada`; a label group `esforco` with `baixo`, `medio`
  and `alto`; and a label group `lane` with one label per agent (`claude`, `codex`…). The ids are looked up
  by name once and cached in `~/.transcentia/lanes/linear-ids.json`.
Check what the dispatcher would do, without touching anything:

```bash
python3 ~/.transcentia/lanes/dispatcher.py --dry-run
```

The app schedules the dispatcher in real mode, but it only takes cards for the lanes you enable in
*Ajustes › Lanes*. When the dry run looks right, enable one lane, and run `tools/install.sh` again
without `--sem-launchd` to register the watcher.

## Model lists

The settings list the models of each lane from the CLIs (`opencode models`, `grok models`), from the
cache the Codex CLI keeps (`~/.codex/models_cache.json`) and from the official APIs when a key is in the
environment (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). Without a list, a fixed model typed by hand still works.

## Tests

```bash
python3 -m unittest discover -s tests -t .
python3 -m unittest lanes.test_lanes
cd apps/notch-mac && swift test
```

## Project layout

```
agents.d/          one manifest per agent
apps/notch-mac/    the macOS app (GastoCore library + NotchGasto app)
bots/              watcher, its prompts and launchd templates
docs/              gasto CLI reference, example data for the screenshot
gasto_lanes/       Python: config, catalog, projects, Linear ids, cost ledger
lanes/             dispatcher, lane runner, tmux window, lane prompts
tests/             Python tests and synthetic fixtures
tools/             cfg reader, installer, panels, usage measure, helpers
```

## Not affiliated

TuttiDash is an independent project. It is not affiliated with, endorsed by or sponsored by Anthropic,
OpenAI, xAI, Cursor, Google, GitHub, Linear or the OpenCode project. Product names are used only to
say which tools it works with.

## License

[MIT](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
