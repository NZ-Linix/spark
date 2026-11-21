/**
 * Builds spark-bridge, one file with no Bun needed to run it. SPARK_DEFAULT_RELAY sets the relay it
 * uses, and SPARK_RELAY_ENROLL the secret that relay asks of new Macs. Keep a build with the secret
 * to yourself.
 */
import { $ } from "bun";
const relay = process.env.SPARK_DEFAULT_RELAY ?? "http://127.0.0.1:8799";
const out = process.argv[2] ?? "dist/spark-bridge";
const enroll = process.env.SPARK_RELAY_ENROLL ?? "";
await $`bun build mac.ts --compile --minify --outfile ${out} --define ${`process.env.SPARK_DEFAULT_RELAY=${JSON.stringify(relay)}`} --define ${`process.env.SPARK_RELAY_ENROLL=${JSON.stringify(enroll)}`}`;
// macOS kills the compiled binary unless it is signed again after Bun writes it
if (process.platform === "darwin") await $`codesign --force --sign - ${out}`.quiet();
console.log(`${out} (relay ${relay}${enroll ? ", with an enrollment secret" : ""})`);
