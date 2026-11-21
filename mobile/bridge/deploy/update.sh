#!/bin/sh
# Installs a new relay and spark on the relay server. The deploy key's
# authorized_keys entry forces this script, so the key can do nothing else.
# It reads a tar with `relay` and `spark` on stdin, checks both run, swaps
# them in, restarts the relay, and puts the old ones back if it doesn't answer.
set -eu

ROOT="${SPARK_RELAY_ROOT:-$HOME/spark-relay}"
BIN="$ROOT/bin"
STAGE="$ROOT/incoming"
HEALTH="${SPARK_RELAY_HEALTH:-http://127.0.0.1:8787/api/info}"

rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -x -C "$STAGE" -f - relay spark
chmod 755 "$STAGE/relay" "$STAGE/spark"

new_version=$("$STAGE/spark" --version)
echo "new spark $new_version"

for f in relay spark; do cp -p "$BIN/$f" "$BIN/$f.bak"; done
for f in relay spark; do mv "$STAGE/$f" "$BIN/$f"; done
rmdir "$STAGE"

sudo -n systemctl restart spark-relay
i=0
while [ "$i" -lt 15 ]; do
  if curl -fsS -m 2 "$HEALTH" >/dev/null 2>&1; then
    echo "relay is up with spark $new_version"
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

echo "relay didn't answer; restoring the previous binaries" >&2
for f in relay spark; do mv "$BIN/$f.bak" "$BIN/$f"; done
sudo -n systemctl restart spark-relay
exit 1
