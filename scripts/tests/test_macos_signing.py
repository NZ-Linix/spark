from __future__ import annotations

import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "sign-and-notarize-macos.sh"
RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"
SIGNING_IDENTITY = "Developer ID Application: Example (EXAMPLE123)"
TEST_CDHASH = "0123456789abcdef0123456789abcdef01234567"
SECRET_NAMES = (
    "APPLE_DEVELOPER_ID_P12_BASE64",
    "APPLE_DEVELOPER_ID_P12_PASSWORD",
    "APPLE_NOTARY_KEY_P8_BASE64",
    "APPLE_NOTARY_KEY_ID",
    "APPLE_NOTARY_ISSUER_ID",
)


class MacosSigningScriptTests(unittest.TestCase):
    def write_tool(self, root: pathlib.Path, name: str, body: str) -> pathlib.Path:
        path = root / name
        path.write_text(
            "#!/usr/bin/env python3\n" + textwrap.dedent(body),
            encoding="utf-8",
        )
        path.chmod(0o755)
        return path

    def make_tools(self, root: pathlib.Path) -> dict[str, pathlib.Path]:
        tools = root / "tools"
        tools.mkdir()

        openssl = self.write_tool(
            tools,
            "openssl",
            r'''
import base64
import os
import pathlib
import sys

args = sys.argv[1:]
if args[:2] == ["rand", "-hex"]:
    print("temporary-keychain-password")
    raise SystemExit(0)
if args and args[0] == "base64":
    output = pathlib.Path(args[args.index("-out") + 1])
    output.write_bytes(base64.b64decode(sys.stdin.buffer.read()))
    raise SystemExit(0)
raise SystemExit(f"unexpected openssl arguments: {args}")
''',
        )
        security = self.write_tool(
            tools,
            "security",
            f'''
import os
import pathlib
import sys

args = sys.argv[1:]
event_log = pathlib.Path(os.environ["SPARK_SIGNING_TEST_LOG"])
with event_log.open("a") as log:
    log.write("security " + " ".join(args) + "\\n")
if args and args[0] == os.environ.get("SPARK_SIGNING_TEST_SECURITY_FAIL_COMMAND"):
    print("injected security failure", file=sys.stderr)
    raise SystemExit(1)
if args and args[0] == "set-key-partition-list":
    import_event = next(
        line
        for line in event_log.read_text(encoding="utf-8").splitlines()
        if line.startswith("security import ")
    )
    partition_list = args[args.index("-S") + 1] if "-S" in args else ""
    key_type = args[args.index("-t") + 1] if "-t" in args else ""
    search_list_configured = any(
        line.startswith("security list-keychains -d user -s ")
        for line in event_log.read_text(encoding="utf-8").splitlines()
    )
    if (
        "-s" in args
        or partition_list != "apple-tool:,apple:"
        or key_type != "private"
        or "-l" in args
        or not search_list_configured
        or " -t cert " in f" {{import_event}} "
    ):
        print("error: The specified item could not be found in the keychain.", file=sys.stderr)
        raise SystemExit(1)
if args and args[0] == "find-identity":
    print('  1) 0123456789ABCDEF0123456789ABCDEF01234567 "{SIGNING_IDENTITY}"')
    print("     1 valid identities found")
''',
        )
        codesign = self.write_tool(
            tools,
            "codesign",
            f'''
import os
import pathlib
import sys

args = sys.argv[1:]
with pathlib.Path(os.environ["SPARK_SIGNING_TEST_LOG"]).open("a") as log:
    log.write("codesign " + " ".join(args) + "\\n")
if os.environ.get("SPARK_SIGNING_TEST_CODESIGN_FAIL_STAGE") == "sign" and "--force" in args:
    print("injected codesign failure", file=sys.stderr)
    raise SystemExit(1)
if "--force" in args:
    binary = pathlib.Path(args[-1])
    binary.write_bytes(binary.read_bytes() + b"signed\\n")
if "--display" in args:
    identifier = os.environ.get("SPARK_SIGNING_TEST_IDENTIFIER", "io.github.nz-linix.spark")
    team_id = os.environ.get("SPARK_SIGNING_TEST_TEAM_ID", "EXAMPLE123")
    print(f"Identifier={{identifier}}", file=sys.stderr)
    print(f"TeamIdentifier={{team_id}}", file=sys.stderr)
    print("CDHash={TEST_CDHASH}", file=sys.stderr)
''',
        )
        ditto = self.write_tool(
            tools,
            "ditto",
            r'''
import os
import pathlib
import sys

args = sys.argv[1:]
with pathlib.Path(os.environ["SPARK_SIGNING_TEST_LOG"]).open("a") as log:
    log.write("ditto " + " ".join(args) + "\n")
pathlib.Path(args[-1]).write_bytes(b"notary archive")
''',
        )
        xcrun = self.write_tool(
            tools,
            "xcrun",
            f'''
import json
import os
import pathlib
import sys

args = sys.argv[1:]
with pathlib.Path(os.environ["SPARK_SIGNING_TEST_LOG"]).open("a") as log:
    log.write("xcrun " + " ".join(args[:2]) + "\\n")
if len(args) > 1 and args[1] == os.environ.get("SPARK_SIGNING_TEST_XCRUN_FAIL_COMMAND"):
    print("injected xcrun failure", file=sys.stderr)
    raise SystemExit(1)
if args[:2] == ["lipo", "-archs"]:
    print(os.environ.get("SPARK_SIGNING_TEST_ARCHS", "arm64"))
elif args[:2] == ["notarytool", "submit"]:
    status = os.environ.get("SPARK_SIGNING_TEST_SUBMISSION_STATUS", "Accepted")
    print(json.dumps({{"id": "test-submission", "status": status}}))
elif args[:2] == ["notarytool", "log"]:
    issues = json.loads(os.environ.get("SPARK_SIGNING_TEST_NOTARY_ISSUES", "null"))
    ticket_cdhash = os.environ.get("SPARK_SIGNING_TEST_TICKET_CDHASH", "{TEST_CDHASH}")
    pathlib.Path(args[-1]).write_text(json.dumps({{
        "status": "Accepted",
        "statusSummary": "Ready for distribution",
        "statusCode": 0,
        "issues": issues,
        "ticketContents": [{{"cdhash": ticket_cdhash, "arch": "arm64"}}],
    }}))
else:
    raise SystemExit(f"unexpected xcrun arguments: {{args}}")
''',
        )
        return {
            "SPARK_SIGNING_OPENSSL_BIN": openssl,
            "SPARK_SIGNING_SECURITY_BIN": security,
            "SPARK_SIGNING_CODESIGN_BIN": codesign,
            "SPARK_SIGNING_DITTO_BIN": ditto,
            "SPARK_SIGNING_XCRUN_BIN": xcrun,
        }

    def run_script(
        self,
        root: pathlib.Path,
        extra_env: dict[str, str] | None = None,
        page_size: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path, pathlib.Path, pathlib.Path]:
        runner_temp = root / "runner-temp"
        runner_temp.mkdir()
        tool_paths = self.make_tools(root)
        binary = root / "spark"
        binary.write_bytes(b"unsigned\n")
        binary.chmod(0o755)
        event_log = root / "events.log"
        env = os.environ.copy()
        env.update(
            {
                "RUNNER_TEMP": str(runner_temp),
                "SPARK_SIGNING_TEST_LOG": str(event_log),
                "APPLE_DEVELOPER_ID_P12_BASE64": base64.b64encode(
                    b"p12-private-material"
                ).decode(),
                "APPLE_DEVELOPER_ID_P12_PASSWORD": "p12-password",
                "APPLE_NOTARY_KEY_P8_BASE64": base64.b64encode(
                    b"p8-private-material"
                ).decode(),
                "APPLE_SIGNING_TEAM_ID": "EXAMPLE123",
                "APPLE_NOTARY_KEY_ID": "TESTKEY123",
                "APPLE_NOTARY_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
            }
        )
        env.update({key: str(value) for key, value in tool_paths.items()})
        if extra_env:
            env.update(extra_env)
        result = subprocess.run(
            [str(SCRIPT_PATH), str(binary)]
            + ([page_size] if page_size is not None else []),
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        return result, binary, runner_temp, event_log

    def test_selects_native_defaults_and_preserves_explicit_page_sizes(self) -> None:
        for arch, page_size, expected in (
            ("arm64", None, "16384"),
            ("x86_64", None, "4096"),
            ("arm64 x86_64", None, "4096"),
            ("x86_64 arm64", None, "4096"),
            ("x86_64", "4096", "4096"),
            ("arm64", "4096", "4096"),
            ("arm64", "16384", "16384"),
        ):
            with self.subTest(arch=arch, page_size=page_size):
                with tempfile.TemporaryDirectory(prefix="spark-signing-pages-") as tmp:
                    result, _, runner_temp, event_log = self.run_script(
                        pathlib.Path(tmp),
                        {"SPARK_SIGNING_TEST_ARCHS": arch},
                        page_size,
                    )
                    self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                    self.assertIn(f"--pagesize {expected} ", event_log.read_text())
                    self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_unsupported_page_sizes_before_importing_credentials(self) -> None:
        for arch, page_size in (
            ("arm64", "8192"),
            ("arm64", "0"),
            ("arm64", ""),
            ("arm64", "--force"),
            ("x86_64", "16384"),
            ("arm64 x86_64", "16384"),
            ("x86_64 arm64", "16384"),
            ("", "16384"),
        ):
            with self.subTest(arch=arch, page_size=page_size):
                with tempfile.TemporaryDirectory(prefix="spark-signing-pages-") as tmp:
                    result, binary, runner_temp, event_log = self.run_script(
                        pathlib.Path(tmp),
                        {"SPARK_SIGNING_TEST_ARCHS": arch},
                        page_size,
                    )
                    self.assertNotEqual(0, result.returncode)
                    self.assertEqual(b"unsigned\n", binary.read_bytes())
                    events = event_log.read_text() if event_log.exists() else ""
                    self.assertNotIn("security import", events)
                    self.assertEqual([], list(runner_temp.iterdir()))

    def test_signs_notarizes_and_cleans_credentials_without_printing_secrets(
        self,
    ) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)
            p12_secret = "p12-private-material"
            p8_secret = "p8-private-material"
            p12_password = "p12-password"
            result, binary, runner_temp, event_log = self.run_script(root)

            output = result.stdout + result.stderr
            self.assertEqual(0, result.returncode, output)
            self.assertEqual(b"unsigned\nsigned\n", binary.read_bytes())
            self.assertIn("test-submission", output)
            self.assertNotIn(p12_secret, output)
            self.assertNotIn(p8_secret, output)
            self.assertNotIn(p12_password, output)
            self.assertEqual([], list(runner_temp.iterdir()))
            events = event_log.read_text(encoding="utf-8")
            self.assertIn("security import", events)
            self.assertIn("security delete-keychain", events)
            self.assertIn("codesign --force", events)
            self.assertIn("--identifier io.github.nz-linix.spark", events)
            self.assertIn("--options runtime", events)
            self.assertIn("--timestamp", events)
            self.assertIn("xcrun notarytool submit", events)
            self.assertIn("xcrun notarytool log", events)

    def test_imports_pkcs12_private_key_for_codesign_and_security(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)
            result, _, _, event_log = self.run_script(root)

            output = result.stdout + result.stderr
            self.assertEqual(0, result.returncode, output)
            import_event = next(
                line
                for line in event_log.read_text(encoding="utf-8").splitlines()
                if line.startswith("security import ")
            )
            self.assertNotIn(" -t cert ", f" {import_event} ")
            self.assertIn(" -f pkcs12 ", f" {import_event} ")
            self.assertIn(" -T /usr/bin/codesign ", f" {import_event} ")
            self.assertIn(" -T /usr/bin/security ", f" {import_event} ")
            partition_event = next(
                line
                for line in event_log.read_text(encoding="utf-8").splitlines()
                if line.startswith("security set-key-partition-list ")
            )
            partition_args = partition_event.split()[2:]
            self.assertEqual(
                "apple-tool:,apple:",
                partition_args[partition_args.index("-S") + 1],
            )
            self.assertEqual(
                "private",
                partition_args[partition_args.index("-t") + 1],
            )
            self.assertNotIn("-l", partition_args)
            self.assertNotIn("-s", partition_args)
            self.assertNotIn("codesign:", partition_args)
            events = event_log.read_text(encoding="utf-8").splitlines()
            search_index = next(
                index
                for index, line in enumerate(events)
                if line.startswith("security list-keychains -d user -s ")
            )
            partition_index = events.index(partition_event)
            self.assertLess(search_index, partition_index)

    def test_reports_failing_signing_stage_without_printing_secrets(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        cases = (
            (
                {"SPARK_SIGNING_TEST_XCRUN_FAIL_COMMAND": "-archs"},
                "architecture inspection",
            ),
            (
                {"SPARK_SIGNING_TEST_SECURITY_FAIL_COMMAND": "import"},
                "PKCS#12 import",
            ),
            (
                {"SPARK_SIGNING_TEST_SECURITY_FAIL_COMMAND": "list-keychains"},
                "keychain search configuration",
            ),
            (
                {"SPARK_SIGNING_TEST_SECURITY_FAIL_COMMAND": "set-key-partition-list"},
                "private-key ACL configuration",
            ),
            (
                {"SPARK_SIGNING_TEST_SECURITY_FAIL_COMMAND": "find-identity"},
                "signing identity lookup",
            ),
            (
                {"SPARK_SIGNING_TEST_CODESIGN_FAIL_STAGE": "sign"},
                "code signing",
            ),
            (
                {"SPARK_SIGNING_TEST_XCRUN_FAIL_COMMAND": "submit"},
                "notarization submission",
            ),
        )
        for extra_env, stage in cases:
            with self.subTest(stage=stage):
                with tempfile.TemporaryDirectory(
                    prefix="spark-macos-signing-test-"
                ) as tmp:
                    root = pathlib.Path(tmp)
                    result, _, _, _ = self.run_script(root, extra_env)

                    output = result.stdout + result.stderr
                    self.assertNotEqual(0, result.returncode, output)
                    self.assertIn(f"Apple signing failed during {stage}", output)
                    self.assertNotIn("p12-password", output)
                    self.assertNotIn("p8-private-material", output)

    def test_rejects_notarization_log_issues_and_cleans_credentials(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)
            issues = json.dumps(
                [
                    {
                        "severity": "warning",
                        "message": "unexpected notarization warning",
                    }
                ]
            )

            result, _, runner_temp, event_log = self.run_script(
                root,
                {"SPARK_SIGNING_TEST_NOTARY_ISSUES": issues},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("notarization log contains issues", output)
            self.assertEqual([], list(runner_temp.iterdir()))
            self.assertIn(
                "security delete-keychain",
                event_log.read_text(encoding="utf-8"),
            )

    def test_rejects_empty_secret_without_echoing_credential_material(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {"APPLE_DEVELOPER_ID_P12_BASE64": ""},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn(
                "Missing required environment variable: "
                "APPLE_DEVELOPER_ID_P12_BASE64",
                output,
            )
            self.assertNotIn("p12-password", output)
            self.assertNotIn("p8-private-material", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_an_imported_identity_from_the_wrong_apple_team(self) -> None:
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            result, _, runner_temp, event_log = self.run_script(
                pathlib.Path(tmp),
                {"APPLE_SIGNING_TEAM_ID": "WRONGTEAM1"},
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("identity for the configured Apple team", result.stderr)
            self.assertNotIn("codesign --force", event_log.read_text())
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_signature_from_the_wrong_apple_team(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {"SPARK_SIGNING_TEST_TEAM_ID": "WRONGTEAM1"},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("wrong team identifier", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_signature_with_the_wrong_identifier(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {"SPARK_SIGNING_TEST_IDENTIFIER": "com.example.spark"},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("wrong signing identifier", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_notarization_ticket_for_another_binary(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {
                    "SPARK_SIGNING_TEST_TICKET_CDHASH":
                        "ffffffffffffffffffffffffffffffffffffffff"
                },
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("ticket does not match", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_failed_notarization_submission(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="spark-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, event_log = self.run_script(
                root,
                {"SPARK_SIGNING_TEST_SUBMISSION_STATUS": "Invalid"},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("notarization failed with status: Invalid", output)
            self.assertNotIn(
                "xcrun notarytool log",
                event_log.read_text(encoding="utf-8"),
            )
            self.assertEqual([], list(runner_temp.iterdir()))


class MacosSigningWorkflowTests(unittest.TestCase):
    def test_validation_builds_existing_versions_without_publishing(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        check_job = release.split("  check-version:\n", 1)[1].split(
            "\n  build-linux:", 1
        )[0]
        check_script = textwrap.dedent(check_job.split("        run: |\n", 1)[1])
        for validate, tag_exists, expected_needed, expected_publish in (
            ("true", True, "true", "false"),
            ("true", False, "true", "false"),
            ("false", True, "false", "false"),
            ("false", False, "true", "true"),
        ):
            with self.subTest(validate=validate, tag_exists=tag_exists):
                with tempfile.TemporaryDirectory(prefix="spark-release-check-") as tmp:
                    root = pathlib.Path(tmp)
                    (root / "src").mkdir()
                    (root / "src/main.zig").write_text(
                        'pub const version = "0.0.8";\n'
                    )
                    git = root / "git"
                    git.write_text(f"#!/bin/sh\nexit {0 if tag_exists else 1}\n")
                    git.chmod(0o755)
                    output = root / "outputs"
                    env = dict(
                        os.environ,
                        PATH=f"{root}:{os.environ['PATH']}",
                        GITHUB_OUTPUT=str(output),
                        VALIDATE_ONLY=validate,
                    )
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", check_script],
                        cwd=root, env=env, capture_output=True, text=True,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertIn(f"needed={expected_needed}\n", output.read_text())
                    self.assertIn(f"publish={expected_publish}\n", output.read_text())
                    self.assertIn("version=v0.0.8\n", output.read_text())

    def test_validation_keeps_both_arm64_signatures(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        step = release.split(
            "      - name: Sign and notarize stable release candidate\n", 1
        )[1].split("\n      - name:", 1)[0]
        run = step.split("        run: ", 1)[1]
        script = textwrap.dedent(run[2:]) if run.startswith("|\n") else run.strip()
        for validate in ("true", "false"):
            with self.subTest(validate=validate):
                with tempfile.TemporaryDirectory(prefix="spark-signing-route-") as tmp:
                    root = pathlib.Path(tmp)
                    (root / "scripts").mkdir()
                    signer = root / "scripts/sign-and-notarize-macos.sh"
                    signer.write_text(
                        "#!/bin/sh\nprintf '%s' \"${2-default}\" >> \"$1\"\n"
                    )
                    signer.chmod(0o755)
                    candidate = root / "zig-out/bin/spark"
                    candidate.parent.mkdir(parents=True)
                    candidate.write_bytes(b"native:")
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", script],
                        cwd=root,
                        env=dict(
                            os.environ, RUNNER_TEMP=str(root), VALIDATE_ONLY=validate,
                        ),
                        capture_output=True, text=True,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    control = root / "spark-signing-control/spark"
                    if validate == "true":
                        self.assertEqual(b"native:16384", candidate.read_bytes())
                        self.assertEqual(b"native:4096", control.read_bytes())
                    else:
                        self.assertEqual(b"native:default", candidate.read_bytes())
                        self.assertFalse(control.exists())

    def test_every_privileged_publish_job_uses_an_environment_gate(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")

        release_job = release.split("  release:\n", 1)[1]

        self.assertIn("environment: release", release_job)
        prerelease_job = release.split("  publish-prerelease:\n", 1)[1]
        self.assertIn("environment: prerelease", prerelease_job)

    def test_stable_release_is_the_only_workflow_with_signing_secrets(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertEqual(2, release.count("environment: apple-signing"))
        self.assertIn(
            "needs: [check-version, build-linux, build-macos-x86_64, build-macos-arm64]",
            release,
        )
        intel_job = release.split("  build-macos-x86_64:\n", 1)[1].split(
            "\n  build-macos-arm64:", 1
        )[0]
        sign_release = release.split("  build-macos-arm64:\n", 1)[1].split(
            "\n  release:", 1
        )[0]
        for job, runner in ((intel_job, "macos-15-intel"), (sign_release, "macos-15")):
            self.assertIn(f"runs-on: {runner}", job)
            self.assertIn("environment: apple-signing", job)
            self.assertIn("needs: check-version", job)
            build = job.index("zig build")
            signing = job.index("scripts/sign-and-notarize-macos.sh")
            notarization = job.index("codesign --verify --strict --check-notarization")
            smoke = job.index("--version", notarization)
            archive = job.index("tar -czf", smoke)
            self.assertLess(build, signing)
            self.assertLess(signing, notarization)
            self.assertLess(notarization, smoke)
            self.assertLess(smoke, archive)
            for secret in SECRET_NAMES:
                self.assertIn(f"${{{{ secrets.{secret} }}}}", job)
        for workflow in RELEASE_WORKFLOW_PATH.parent.glob("*.yml"):
            if workflow == RELEASE_WORKFLOW_PATH:
                continue
            contents = workflow.read_text(encoding="utf-8")
            self.assertNotIn("environment: apple-signing", contents, workflow.name)
            self.assertNotIn("sign-and-notarize-macos", contents, workflow.name)
            for secret in SECRET_NAMES:
                self.assertNotIn(secret, contents, workflow.name)

    def test_release_pins_every_external_action(self) -> None:
        mutable_references: list[str] = []
        pending = [RELEASE_WORKFLOW_PATH]
        checked: set[pathlib.Path] = set()
        while pending:
            path = pending.pop()
            if path in checked:
                continue
            checked.add(path)
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(),
                start=1,
            ):
                local = re.search(r"uses:\s+\./(\S+)", line)
                if local:
                    target = REPO_ROOT / local.group(1)
                    pending.append(target if target.suffix == ".yml" else target / "action.yml")
                    continue
                match = re.search(r"uses:\s+([^\s@]+)@([^\s#]+)", line)
                if match and not re.fullmatch(r"[0-9a-f]{40}", match.group(2)):
                    mutable_references.append(
                        f"{path.relative_to(REPO_ROOT)}:{line_number}: {line.strip()}"
                    )

        self.assertEqual([], mutable_references)


class LinuxReleaseWorkflowTests(unittest.TestCase):
    def release_job(self, name: str) -> str:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        return re.split(
            r"\n  (?=\S)", release.split(f"\n  {name}:\n", 1)[1], maxsplit=1
        )[0]

    def test_release_builds_smoke_tests_and_packages_all_linux_targets(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        build = self.release_job("build-linux")
        self.assertNotIn("./.github/workflows/pgso-", release)
        self.assertIn("runs-on: ${{ matrix.runner }}", build)
        self.assertIn("timeout-minutes: 10", build)
        for name, runner, target, cpu in (
            ("linux-x86_64", "ubuntu-24.04", "x86_64-linux-gnu.2.34", "baseline"),
            ("linux-aarch64", "ubuntu-24.04-arm", "aarch64-linux-gnu.2.34", "baseline"),
            ("linux-x86", "ubuntu-24.04", "x86-linux-musl", "i686"),
        ):
            self.assertIn(
                f"          - name: {name}\n"
                f"            runner: {runner}\n"
                f"            target: {target}\n"
                f"            cpu: {cpu}",
                build,
            )
        self.assertNotIn("environment:", build)
        compile_step = build.index("zig build")
        smoke = build.index("./zig-out/bin/spark --version")
        archive = build.index("tar -czf")
        self.assertLess(compile_step, smoke)
        self.assertLess(smoke, archive)
        self.assertIn('cp zig-out/bin/spark LICENSE THIRD_PARTY_NOTICES.md', build)
        self.assertIn('sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"', build)

    def test_only_release_and_platform_ci_workflows_are_defined(self) -> None:
        self.assertEqual(
            {"ci.yml", "macos.yml", "release.yml"},
            {path.name for path in RELEASE_WORKFLOW_PATH.parent.glob("*.yml")},
        )

    def test_release_rejects_missing_or_changed_archives(self) -> None:
        release = self.release_job("release")
        step = release.split(
            "      - name: Verify and publish all release archives\n", 1
        )[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        targets = ("linux-x86_64", "linux-aarch64", "linux-x86", "macos-x86_64", "macos-aarch64")
        for failure in (None, "missing", "changed"):
            with self.subTest(failure=failure):
                with tempfile.TemporaryDirectory(prefix="spark-release-archives-") as tmp:
                    root = pathlib.Path(tmp)
                    dist = root / "dist"
                    dist.mkdir()
                    for target in targets:
                        archive = dist / f"spark-{target}.tar.gz"
                        payload = target.encode()
                        archive.with_suffix(".gz.sha256").write_text(
                            f"{hashlib.sha256(payload).hexdigest()}  {archive.name}\n"
                        )
                        if target == "linux-x86" and failure == "missing":
                            continue
                        archive.write_bytes(b"changed" if target == "linux-x86" and failure else payload)
                    gh = root / "gh"
                    gh.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > published\n')
                    gh.chmod(0o755)
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", script],
                        cwd=root,
                        env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", TAG="v26.11.20", GITHUB_SHA="0" * 40),
                        capture_output=True,
                        text=True,
                    )
                    if failure is None:
                        self.assertEqual(0, result.returncode, result.stderr)
                        self.assertIn("--latest", (root / "published").read_text())
                    else:
                        self.assertNotEqual(0, result.returncode)
                        self.assertFalse((root / "published").exists())


if __name__ == "__main__":
    unittest.main()
