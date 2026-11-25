```text
                      _
 ___ _ __   __ _ _ __| | __
/ __| '_ \ / _` | '__| |/ /
\__ \ |_) | (_| | |  |   <
|___/ .__/ \__,_|_|  |_|\_\    -=✦
    |_|
```

**A fast, native coding agent for your terminal.**

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

Alternatively:

```bash
wget -qO- https://raw.githubusercontent.com/NZ-Linix/spark/main/install.sh | sh
```

Windows (PowerShell, installs into WSL):

```powershell
irm https://raw.githubusercontent.com/NZ-Linix/spark/main/install.ps1 | iex
```

The installer puts `spark` in `~/.local/bin`. Run `sh -s -- --help` after the pipe for options such as `--version` and `--uninstall`.

On iSH for iPhone or iPad, use the `wget` command above. The installer selects the static 32-bit `linux-x86` build. If an older binary can't update itself, re-run the installer; it replaces the binary without touching your sessions or settings.

### Update

```bash
spark update
```

Inside spark, `/update` installs the newest release and restarts into the same session. spark also checks for updates in the background and shows `ctrl+g to reload` when one is ready.

### Uninstall

Close other spark sessions, then run `spark uninstall`. Confirm to delete the running binary, the default profile at `~/.spark`, and spark's local Keychain credentials on macOS. This permanently removes saved sessions and settings. Use `spark uninstall --yes` from a script.

If you set `SPARK_HOME`, back up or remove that profile separately and unset the variable before running the command. To remove only the installed binary, pass `--uninstall` to the installer script.

### Build from source

You need [Zig 0.17.1](https://ziglang.org/download/) or newer.

```bash
git clone https://github.com/NZ-Linix/spark.git
cd spark
zig build
./zig-out/bin/spark
```

## Quick start

Start spark in a project and add a model provider:

```text
/provider
```

Choose **Add connection** to set an OpenAI-compatible base URL, API key (empty for a local server), and models. Spark saves the provider in `~/.spark/settings.json` and switches to it.

Choose **Continue with ChatGPT** to connect an eligible ChatGPT plan instead. No API key or Codex installation is needed: Spark sends its own prompts and tools using OpenAI's [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source). Give accounts labels such as `Work` and `Personal`, or leave the label blank for a numbered account. Choose an account under `/provider`, then pick from that account's models and reasoning levels. OAuth credentials stay in the private `chatgpt-plan` folder in your Spark profile. To disconnect, open the account in `/provider` and choose **Disconnect account**.

Then just type what you want done.

For one request without the interactive shell:

```bash
spark ask "explain the changes in this repository"
spark ask --json "summarize the failing tests" | jq -r .final_output
```

## In the shell

| Command    | What it does                                                         |
| ---------- | -------------------------------------------------------------------- |
| `/provider` | Add, edit, rename, or delete model providers                        |
| `/model`   | Switch models                                                        |
| `/prompt`  | Pick a custom system prompt from your prompt folders; Tab stars one  |
| `/mcp`     | Manage MCP servers                                                   |
| `/help`    | List every command                                                   |

The model's thinking shows as one `Thought for 3s` line; Ctrl+O expands every thinking block to the reasoning behind it, and collapses them again. Alt+O (or Cmd+O) opens the full transcript, including tool details and reasoning.

Use `/context` to see the current session's context window, `/context 64k` to set a ceiling, or `/context auto` to use the model default. The ceiling survives resume, never raises the model's own window, and makes automatic compaction kick in earlier. `/compact` summarizes older history on demand without removing it from the saved transcript. On iPhone and iPad, choose **Context limit** in the model picker.

Keeping the same model and using compaction only when needed helps preserve the cached prompt prefix. Direct Anthropic connections use automatic prompt caching for agent requests. Actual cache hits depend on the provider, prompt size, and time between requests.

The footer shows the latest reported context usage and this run's token totals: `↑` uncached input, `↓` output, `R` cache reads, `W` cache writes, and `CH` the cache hit rate for requests that report cache usage. Hide the segment with `spark config set status_line.context false`.

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

The end-to-end tests in [`tests/e2e/`](tests/e2e) drive the built binary through tmux and need [Bun](https://bun.sh).

## License

[Apache-2.0](LICENSE). spark is a fork of [fx](https://github.com/vercel-labs/fx). Third-party licenses and attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
