# Decided names

Names the maintainers already settled. Reuse them; don't add another spelling. "Planned" means not built yet: design toward it, but don't tell users to run it.

## Resume

| Spelling | Opens | Status |
|---|---|---|
| `spark -c`, `spark --continue` | The session you last worked in interactively | Keep |
| `spark -r [last\|<id>]`, `spark --resume [last\|<id>]` | One flag in short and long form. With no value, the session picker, the same list as `/resume`. `last` opens the newest saved session, and an ID opens that one | Keep |
| `spark session resume [last\|<id>]` | The newest saved session (also with no value), or an exact one | Keep |
| `spark ask --resume <last\|<id>>` | Same, for one-shot runs | Keep |
| `/resume` | Inside a session | Keep |
| `spark --resume-last`, `spark --resume-<id>`, hidden `spark resume`, the `--id <id>` forms, `spark ask --resume-id`, `--resume --last` | Duplicates of the above | Removed. Each fails with exit 2 and names its replacement. `spark resume <id> --upgrade-relaunch` stays as the internal restart after an upgrade |

"Newest" includes sessions `spark ask` created; "where I left off" doesn't, because `spark ask` never records the remembered session.

## Permission mode

| Surface | Name |
|---|---|
| Setting | `permission_mode`: `ask`, `auto`, or `full-access` (legacy `yolo` is read until spark 26.12.20, never written) |
| Flag | `--permission-mode <mode>`, with aliases `--ask`, `--auto`, `--full-access`, `--yolo` |
| Env var | `SPARK_PERMISSION_MODE` |
| Slash command | `/permissions [ask\|auto\|full-access\|reset]` |
| Read-only view | `spark permissions` |

## Scopes

| Word | Means |
|---|---|
| `--global` | The profile, `~/.spark/settings.json` |
| `--workspace` | This folder's entry in the profile |
| `--project` | A committed file in the repo, only for commands that write one (`spark mcp` and `.mcp.json`) |

`spark mcp --profile` still works as `--global`, and `/allowlist` still takes `user` (the profile's top level) and `local` (this folder's entry) for `global` and `workspace`; each warns and stops working in spark 26.12.20, and spark always shows the new words.

## Settings and their surfaces

| Concept | Name |
|---|---|
| Settings command | `spark config list\|get\|set\|unset\|schema`; `--global`, `--workspace` (list and get), `--show-origin` |
| Generic per-run override | `spark ask --config key=value`, with the keys `spark config set` takes |
| Sound | `sound.turn_end`, `sound.attention_required`, `sound.max` (the older `notifications.*` is read until spark 26.12.20); `/sound on\|off\|max` and `SPARK_SOUND` are presets for the group |
| Status line | `status_line.*` (the older `statusLine` is read until spark 26.12.20) |
| Experiments | `experimental.<name>`; none today |
| Home | `SPARK_HOME` (default `~/.spark`) |
| Test hooks | `SPARK_TEST_*` |
| Release channel | `update_channel`; `spark upgrade --channel <name>` saves it, the way a setter command does |
| Save a default model | `/model` in a session saves it to the profile. `spark config set` refuses the model keys and points there |
| User aliases | `alias.<name>` (planned); there is no `/alias` command until then |

## Accounts

| Concept | Name |
|---|---|
| Sign in, including pasting an AI Gateway key | `spark login [vercel\|codex\|grok]` |
| Paste an AI Gateway API key | `spark login vercel --api-key`; in a session, `/login` offers sign-in or an API key. `spark setup` and `/setup` warn, stop working in spark 26.12.20, and are hidden from help |
| Choose the active provider | `spark provider <name>`, `/provider` |

## Other

| Concept | Name |
|---|---|
| Shell completion | `spark completion bash\|zsh\|fish` |
| Settings JSON Schema | `spark config schema [--project]`, served at `https://github.com/NZ-Linix/spark` and `https://github.com/NZ-Linix/spark` |
| MCP servers | `spark mcp` (stays the command) |
| Usage and spend | `spark usage`, `/usage` |
| Terminal rendering counters | `/stats` |
| Exit codes | 0 success, 1 failure, 2 usage error |
| Start a session with a first prompt | `spark "<prompt>"`, one quoted argument; after a resume target, `spark -c "<prompt>"` or `spark -r <id\|last> "<prompt>"` |
| Run one request and exit | `spark ask "<prompt>"`; `-p` and `--print` only point to it |
| Versioned JSON | `--json=v2` when a shape must change |
