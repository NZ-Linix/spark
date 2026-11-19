```text
                      _
 ___ _ __   __ _ _ __| | __
/ __| '_ \ / _` | '__| |/ /
\__ \ |_) | (_| | |  |   <
|___/ .__/ \__,_|_|  |_|\_\    -=✦
    |_|
```

**A fast, native coding agent for your terminal.**

One Zig binary · any OpenAI-compatible model · output that stays in your scrollback

> [!WARNING]
> spark is experimental. It runs with full access: every tool call, file edit, and shell command runs without asking first. Use it in projects you can restore.

## Why spark

- **Native and small.** One binary with no runtime to install. It starts in milliseconds.
- **Inline, not fullscreen.** The conversation prints into your terminal like any other command, so you can scroll, search, and copy it.
- **Bring your own model.** Connect any OpenAI-compatible Chat Completions endpoint: OpenRouter, Ollama, LM Studio, vLLM, and others.
- **Your shell.** Commands run in your login shell with your aliases, functions, and `PATH`.
- **Sessions.** Every conversation is saved under `~/.spark/sessions/`. `spark -c` continues the last one.

## Install

macOS and Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/NZ-Linix/spark/main/install.sh | sh
```

Windows (PowerShell, installs into WSL):

```powershell
irm https://raw.githubusercontent.com/NZ-Linix/spark/main/install.ps1 | iex
```

The installer puts `spark` in `~/.local/bin`. Run `sh -s -- --help` after the pipe for options such as `--version` and `--uninstall`.

### Update

```bash
spark update
```

Inside spark, `/update` installs the newest release and restarts into the same session. spark also checks for updates in the background and shows `ctrl+g to reload` when one is ready.

### Build from source

You need [Zig 0.17.1](https://ziglang.org/download/) or newer.

```bash
git clone https://github.com/NZ-Linix/spark.git
cd spark
zig build
./zig-out/bin/spark
```

## Quick start

Start spark in a project and add a model connection:

```text
/connect
```

The form asks for a name, a base URL such as `https://openrouter.ai/api/v1`, an API key (leave it empty for a local server), and one or more models with their context window. spark saves the connection in `~/.spark/settings.json` and switches to it.

Then just type what you want done.

For one request without the interactive shell:

```bash
spark ask "explain the changes in this repository"
spark ask --json "summarize the failing tests" | jq -r .final_output
```

## In the shell

| Command    | What it does                                                         |
| ---------- | -------------------------------------------------------------------- |
| `/connect` | Add, edit, rename, or delete model connections                       |
| `/model`   | Switch models                                                        |
| `/prompt`  | Pick a custom system prompt from your prompt folders; Tab stars one  |
| `/search`  | Choose the web search provider: Vercel, Firecrawl, or auto           |
| `/mcp`     | Manage MCP servers                                                   |
| `/help`    | List every command                                                   |

Ctrl+O opens the full transcript, including tool details and reasoning.

## Extend it

- **Custom system prompts.** Add a folder of `.md` or `.txt` files with `/prompt dir add PATH`, then choose one with `/prompt`. spark sends the chosen file alone as the system prompt.
- **Skills.** Loaded from `.spark/skills`, `~/.spark/skills`, `.claude/skills`, and `.agents/skills`.
- **MCP servers.** Add them with `/mcp` or `spark mcp`.
- **Project instructions.** spark follows `AGENTS.md` in your project and `~/.spark/AGENTS.md`.

## Development

```bash
zig build               # build ./zig-out/bin/spark
zig build test          # unit tests
zig fmt src/            # format
```

The end-to-end tests in [`tests/e2e/`](tests/e2e) drive the built binary through tmux and need [Bun](https://bun.sh). See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## License

[Apache-2.0](LICENSE). spark is a fork of [fx](https://github.com/vercel-labs/fx). Third-party licenses and attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
