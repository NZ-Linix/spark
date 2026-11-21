# spark mobile

A native iPhone app for spark, and the bridge that connects it.

```text
iPhone ──wss──▶ relay ◀──wss── spark-bridge ──stdio──▶ spark acp
                  │
                  └── cloud host ──stdio──▶ spark acp   (runs on the relay's server)
```

- `bridge/mac.ts` builds into `spark-bridge`, a single binary that installs beside spark. `spark pair` runs it.
- `bridge/relay.ts` pairs phones with Macs, carries their messages, and runs cloud sessions when `SPARK_CLOUD_ROOT` is set. Cloud sessions keep working while the Mac is asleep or off.
- `ios/` is the SwiftUI app (iOS 26).

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

With Sections or Merged, a chat opens on its own host, and the new-chat screen has a Cloud and Mac picker that starts on the host you used last. The sidebar checks for new chats every 15 seconds while it's open.

The cloud shows every chat. The Mac shows only the chats started from the phone, plus sessions running on the Mac right now, such as spark in a terminal. A running session counts when its spark process holds the session's lock. `spark-bridge` keeps the phone's chats in `mobile-sessions.json` beside its pairing file and forgets a chat once spark no longer lists it.

## Cloud providers

Settings, Cloud providers manages the models the cloud uses. Add, edit, or delete a provider, or copy one from the Mac. A copy carries every setting, the key, and the models, and is made once: later changes on the Mac stay there.

When the Mac's provider reads its key from an environment variable, `spark-bridge` looks up the value in your login shell and the cloud stores it as a plain key. Header values read from variables are copied too, and the relay passes them only to that phone's cloud spark, kept in `cloud-env.json` in its profile. Variables that change how processes run, such as `PATH` or `DYLD_*`, are refused.

Before it saves, the relay has spark check the new settings and shows spark's reason if it refuses them. The first provider you add becomes the cloud's default.

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

`SparkUITests` walks pair, start, send and reply against a live relay and bridge. `testSidebarLayoutsAndCopyProvider` switches through the sidebar layouts and copies a Mac provider named `local` to the cloud:

```bash
TEST_RUNNER_SPARK_RELAY=http://127.0.0.1:8799 TEST_RUNNER_SPARK_PAIR_CODE=<code> \
TEST_RUNNER_SPARK_SHOTS=/tmp/shots \
xcodebuild test -project Spark.xcodeproj -scheme Spark -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

## Security

The relay authenticates every phone and Mac with a random token and keeps only its hash. Only a Mac whose `spark-bridge` carries the relay's enrollment secret can register, and a phone can register only with a pairing code from one of those Macs, so phones need no setup and strangers can't use the relay or its cloud. `SPARK_RELAY_OPEN=1` drops the pairing code requirement and lets any phone start on the cloud. A paired phone can run anything spark can run on that Mac, so host the relay behind TLS and unpair phones you no longer use. Messages are not end-to-end encrypted: whoever runs the relay can read them.

That includes API keys. Copying or adding a cloud provider sends its key through the relay, and the server stores it in that phone's cloud profile (`settings.json`, mode 0600). Only use a relay you trust with those keys.
