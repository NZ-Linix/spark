# spark mobile

A native iPhone app for spark, and the bridge that connects it.

```text
iPhone ──wss──▶ relay ◀──wss── spark-bridge ──stdio──▶ spark acp
                  │
                  └── cloud host ──stdio──▶ spark acp   (runs on the relay's server)
```

- `bridge/mac.ts` builds into `spark-bridge`, a single binary that installs beside spark. `spark pair` runs it.
- `bridge/relay.ts` pairs phones with Macs, carries their messages, and runs cloud sessions when `SPARK_CLOUD_ROOT` is set. Cloud sessions keep working while the Mac is asleep or off.
- `ios/` is the SwiftUI app for iPhone and iPad (iOS 26).

The relay address is built into both the app and `spark-bridge`, so pairing is just a code.

## Pair a Mac

```bash
spark pair
```

It shows a six-digit code. Type it into the app. Once paired, `spark-bridge` keeps the Mac reachable at login (a LaunchAgent). `spark pair --foreground` serves from the terminal instead. `spark-bridge unpair` stops it and forgets the pairing.

`SPARK_MOBILE_ROOT=~/Developer spark pair` limits the phone's folder picker and new sessions to one folder.

## Chats

The sidebar shows the chats on the cloud and on the Mac. Settings, Sidebar picks one of three layouts:

- **Sections** (the default): one list, with a section for the cloud and one for the Mac.
- **Switch**: one host at a time, chosen with the switch at the top.
- **Merged**: one list by date, with a cloud or Mac badge on each row.

On an iPad, or in any window wide enough, the sidebar stays beside the chat; the sidebar button in the top corner hides it and brings it back, and the chat keeps a readable width. With a hardware keyboard, Command-N starts a new chat, Control-Command-S shows or hides the chats, and Command-Return sends.

With Sections or Merged, a chat opens on its own host, and the new-chat screen has a Cloud and Mac picker that starts on the host you used last. The sidebar checks for new chats every 15 seconds while it's open.

Press and hold a chat in the sidebar to rename or delete it. Press and hold one of your messages to edit it or send it again; under each reply, the arrow takes the chat back to that reply. Either way spark forks the session at that point, the chat goes on in the fork, and the turns after it are gone. In a terminal, `/fork` (or `/rewind`) does the same and puts the prompt back in the composer, keeping the old session. A chat that is running can't be deleted until it stops.

In the folder picker, the row at the top or any part of the path goes up a level, and swiping right does the same. Press and hold a folder to use it, rename it, or delete it with everything inside. The picker refuses to change the host's root folder, the home folder, the folders that hold either, and the standard folders in home such as Documents and Desktop.

The cloud shows every chat. The Mac shows only the chats started from the phone, plus sessions running on the Mac right now, such as spark in a terminal. A running session counts when its spark process holds the session's lock. `spark-bridge` keeps the phone's chats in `mobile-sessions.json` beside its pairing file and forgets a chat once spark no longer lists it.

Open a running Mac chat from the sidebar to see its reply as it streams. You can send a message into the same terminal session, including while spark is working, or stop the active turn. The terminal still owns the session and uses its current model and permissions. The phone doesn't change the terminal's settings or answer its dialogs. Older Mac processes remain read-only until they close; restart them with the updated CLI for live access.

## Providers, prompts, and MCP

The relay keeps one library of providers, prompts, and MCP servers that the cloud and every paired Mac share. It lives in `$SPARK_RELAY_DATA/library`. The first time a relay starts with a library, it fills it from the providers its cloud profiles already have.

Settings, Library, Providers adds, edits, renames, or deletes a provider in a form: display name, ID, protocol, address, key, timeouts, and each model's display name, context window, output limit, tool and image support, and reasoning levels. Fields the form doesn't show, such as headers and request fields, are kept as they were. Before it saves, the relay has spark check the new settings and shows spark's reason if it refuses them. The first provider you add becomes the default.

Each Mac keeps a copy of the library in its own spark profile, so spark in a terminal uses the same providers. `spark-bridge` replaces the providers in `settings.json` with the library's whenever the library changes. A change spark makes on the Mac, such as `spark provider set` or the `/provider` form, goes to the relay within a second and from there to every other Mac and the cloud. When the relay refuses a change, `spark-bridge` logs the reason and puts the Mac's copy back. A key a Mac provider reads from an environment variable is looked up in your login shell and stored in the library as a plain key, and header values read from variables go to the cloud's spark as variables. Variables that change how processes run, such as `PATH` or `DYLD_*`, are refused. The first time a Mac syncs, it adds the providers only it has to the library; for a provider both have, the library's version wins.

`spark provider set <name> [<model>] <field> <value>` changes one field without opening the `/provider` form, for example `spark provider set oc-go display_name "OpenCode Go"` or `spark provider set oc-go glm-5.3 context_window 200k`.

Prompts are edited only in the app: Settings, Library, Prompts. Each prompt has a name and its text, and replaces spark's own system prompt for the chats that pick it. Pick one in the model sheet, from the chip beside the send button. A chat can change its prompt between messages: its spark starts again with the new one. Press and hold a prompt to rename or delete it. Each Mac and cloud profile gets the prompts in `~/.spark/cloud-prompts`, which spark lists with your own prompts. A chat keeps its prompt when it is reopened. After that prompt is renamed or deleted, the chat runs with spark's own prompt the next time it opens.

MCP servers are edited in the app (Settings, Library, MCP Servers) or on any paired Mac with `spark mcp`. A server either runs a command, with arguments and environment variables, or connects to a URL, with headers. The switch beside each server turns it on or off everywhere. The app shows a saved variable or header value only by its last 4 characters, unless the value is a `${NAME}` reference, and leaving it empty keeps it. A Mac sends its own `mcp.json` edits to the relay, as it does with providers, and the first time it syncs it adds the servers only it has. The library keeps them in `$SPARK_RELAY_DATA/library/mcp.json`, spark's usual `mcpServers` object, which can also be edited on the relay. It replaces the server list in each cloud profile and paired Mac's `mcp.json`. On a relay started with `SPARK_RELAY_OPEN=1`, phones can't change MCP servers, because a server's command runs on every paired Mac. Workspace `.mcp.json` files and saved OAuth logins stay local. A shared server must be reachable from the machines using it; configure any required environment variables or credentials there.

The phone's model picker shows the profile MCP servers available on that host. All enabled profile servers start on in a new chat. Turning one off applies to that chat's next message and is remembered when the chat is reopened. This doesn't change the library or the configuration of a session already owned by a Mac terminal.

## Build spark-bridge

```bash
cd bridge && bun install
SPARK_DEFAULT_RELAY=https://relay.example.com SPARK_RELAY_ENROLL="$(cat ~/.spark/relay-enroll)" \
  bun build.ts ../../zig-out/bin/spark-bridge
```

`SPARK_RELAY_ENROLL` is the secret the relay asks of new Macs. The build carries it, so keep that `spark-bridge` to yourself.

## Run the relay

On a server, with TLS in front of it:

```bash
docker build -t spark-relay bridge
docker run -d -p 8787:8787 -v spark-data:/data \
  -v ~/.spark/settings.json:/config/settings.json:ro spark-relay
```

Set `SPARK_RELAY_ENROLL` to a long random secret, the same one `spark-bridge` is built with, and `HOST=127.0.0.1` when TLS runs in front of the relay on the same server. Leave out `SPARK_CLOUD_ROOT` for a relay without cloud sessions. For development, run `cd bridge && PORT=8799 bun relay.ts` on the Mac.

## Build the app

```bash
cd ios
cp Local.example.xcconfig Local.xcconfig   # team ID, bundle ID, relay URL
xcodegen generate
open Spark.xcodeproj
```

### UI test

`SparkUITests` walks pair, start, send, reply, and renaming a chat against a live relay and bridge. `testSidebarLayoutsAndLibrary` switches through the sidebar layouts, opens a provider named `local` from the library, and writes, renames, and deletes a prompt:

```bash
TEST_RUNNER_SPARK_RELAY=http://127.0.0.1:8799 TEST_RUNNER_SPARK_PAIR_CODE=<code> \
TEST_RUNNER_SPARK_SHOTS=/tmp/shots \
xcodebuild test -project Spark.xcodeproj -scheme Spark -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

`testChatScrollAndDisclosure`, `testScrollButtonAndFollowing`, and `testMcpServers` use the local fixture `bun bridge/fixtures/scroll-relay.ts` and a fresh simulator with `TEST_RUNNER_SPARK_SCROLL_FIXTURE=http://127.0.0.1:18772`. The first checks that opening a thought or tool block keeps the row in place, that the model sheet can turn an MCP server off, and that a follow-up reply stays on screen. The other two check that the button back to the newest text goes away when you scroll down by hand and works mid-flick, that a streaming reply is followed to its end, and that MCP servers can be added, turned off, and deleted, without the app getting a saved header value back.

`testTerminalSessionOpensReadOnly` exercises the fallback with an older spark process open in a terminal. Set `TEST_RUNNER_SPARK_HELD_TITLE` to the session's title prefix and quit that process after the screenshot `30-terminal-session-read-only` appears. To exercise live access with the new CLI, run `SPARK_TERMINAL_TEST_BIN=/absolute/path/to/spark bun test tests/e2e/tui-mobile-bridge.test.ts` from the repository root.

## Security

The relay authenticates every phone and Mac with a random token and keeps only its hash. Only a Mac whose `spark-bridge` carries the relay's enrollment secret can register, and a phone can register only with a pairing code from one of those Macs, so phones need no setup and strangers can't use the relay or its cloud. `SPARK_RELAY_OPEN=1` drops the pairing code requirement and lets any phone start on the cloud. A paired phone can run anything spark can run on that Mac, so host the relay behind TLS and unpair phones you no longer use. Messages are not end-to-end encrypted: whoever runs the relay can read them.

That includes API keys. Entering a key in the app, or saving a provider with a key on a Mac, sends the key through the relay. The relay stores it in the library, every cloud profile, and every paired Mac's spark settings (`settings.json`, mode 0600). Every phone paired to the relay can see and change the library. Only use a relay you trust with those keys. Shared MCP definitions can also contain credentials and are copied to every paired Mac. Only put trusted servers in the shared library.
