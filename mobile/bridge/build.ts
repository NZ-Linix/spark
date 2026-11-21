/**
 * Builds spark-bridge, one file with no Bun needed to run it. SPARK_DEFAULT_RELAY sets the relay it
 * uses, and SPARK_RELAY_ENROLL the secret that relay asks of new Macs. Keep a build with the secret
 * to yourself.
 *
 * On macOS it signs the build with SPARK_BRIDGE_SIGN_IDENTITY, or else the first Developer ID
 * Application identity in the keychain, under a fixed identifier. macOS keeps folder access, such
 * as to Desktop, for as long as that signature's requirement stays the same, so a rebuilt bridge
 * doesn't ask again. Without an identity the build is signed ad hoc, and macOS asks again after
 * every build.
 */
import { $ } from "bun";
const relay = process.env.SPARK_DEFAULT_RELAY ?? "http://127.0.0.1:8799";
const out = process.argv[2] ?? "dist/spark-bridge";
const enroll = process.env.SPARK_RELAY_ENROLL ?? "";
const identifier = "io.github.nz-linix.spark-bridge";
await $`bun build mac.ts --compile --minify --outfile ${out} --define ${`process.env.SPARK_DEFAULT_RELAY=${JSON.stringify(relay)}`} --define ${`process.env.SPARK_RELAY_ENROLL=${JSON.stringify(enroll)}`}`;

/** The identity to sign with, or "-" for ad hoc when the keychain has none. */
async function signingIdentity(): Promise<string> {
  const chosen = process.env.SPARK_BRIDGE_SIGN_IDENTITY;
  if (chosen) return chosen;
  const found = await $`security find-identity -v -p codesigning`.quiet().nothrow().text();
  const match = found.match(/^\s*\d+\) ([0-9A-F]{40}) "Developer ID Application: [^"]+"/m);
  return match?.[1] ?? "-";
}

let signed = "ad hoc";
// macOS kills the compiled binary unless it is signed again after Bun writes it
if (process.platform === "darwin") {
  const identity = await signingIdentity();
  await $`codesign --force --sign ${identity} --identifier ${identifier} ${out}`.quiet();
  if (identity !== "-") signed = "signed";
}
console.log(`${out} (relay ${relay}${enroll ? ", with an enrollment secret" : ""}, ${signed})`);
