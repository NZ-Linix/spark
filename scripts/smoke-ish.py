#!/usr/bin/env python3
"""Exercise a Linux x86 spark binary in an unpacked iSH Alpine fakefs."""

import fcntl
import hashlib
import http.server
import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import sys
import tarfile
import tempfile
import termios
import threading
import time


PROMPT = "Can you echo Grüße, café, and 👋?"
PASTED = "Pasted follow-up: Grüße, café, and 👋"
REPLY = "Fixture reply: Grüße, café, and 👋"


class Fixture(http.server.BaseHTTPRequestHandler):
    def send_bytes(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if content_type != "text/event-stream":
            self.wfile.write(data)
            return
        # Split inside UTF-8, not just at SSE or JSON boundaries.
        split = data.index("👋".encode()) + 2
        self.wfile.write(data[:split])
        self.wfile.flush()
        time.sleep(0.05)
        self.wfile.write(data[split:])

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path != "/v1/chat/completions" or body["model"] != "fixture-model":
            self.send_error(404)
            return
        user = next(m["content"] for m in reversed(body["messages"]) if m.get("role") == "user")
        text = user if isinstance(user, str) else "\n".join(part.get("text", "") for part in user)
        if not any(prompt in text for prompt in (PROMPT, PASTED)):
            self.send_error(400, "UTF-8 prompt didn't reach the provider")
            return
        events = [
            {"choices": [{"index": 0, "delta": {"content": REPLY}, "finish_reason": None}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            {"choices": [], "usage": {"prompt_tokens": 48, "completion_tokens": 12}},
        ]
        wire = "".join(f"data: {json.dumps(event, ensure_ascii=False)}\r\n\r\n" for event in events) + "data: [DONE]\r\n\r\n"
        self.send_bytes(wire.encode(), "text/event-stream")

    def do_GET(self):
        if self.path == "/latest/download/latest.txt":
            self.send_bytes(b"v99.1.1\r\n", "text/plain")
        elif self.path == "/download/v99.1.1/spark-linux-x86.tar.gz.sha256":
            self.send_bytes(self.server.checksum, "text/plain")
        elif self.path == "/download/v99.1.1/spark-linux-x86.tar.gz":
            self.send_bytes(self.server.archive, "application/gzip")
        else:
            self.send_error(404)

    def log_message(self, *_):
        pass


def main(binary, ish, root):
    with tempfile.TemporaryDirectory(prefix="spark-ish-") as temp:
        guest = f"/tmp/{pathlib.Path(temp).name}"
        source = pathlib.Path(binary).read_bytes()
        update = pathlib.Path(temp) / "spark"
        update.write_bytes(source + b"spark iSH upgrade fixture\n")
        update.chmod(0o755)
        archive = pathlib.Path(temp) / "update.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(update, "spark")
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
            server.archive = archive.read_bytes()
            server.checksum = (hashlib.sha256(server.archive).hexdigest() + "  spark-linux-x86.tar.gz\n").encode()
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                exercise(source, ish, root, guest, server.server_port, hashlib.sha256(update.read_bytes()).hexdigest())
            finally:
                server.shutdown()
                thread.join()


def exercise(binary, ish, root, guest, port, updated_sha):
    base = f"http://127.0.0.1:{port}"

    def argv(command, *args):
        env = ('export HOME="$1" SPARK_HOME="$1/.spark" TERM=xterm-256color '
               'SPARK_SOUND=0 SPARK_AUTO_UPGRADE=0 SPARK_DISABLE_KEYCHAIN=1; shift; ')
        return [ish, "-f", root, "/bin/sh", "-c", env + command, "smoke", guest, *args]

    def run(command, *args, data=None):
        script = command + '; rc=$?; if [ "$rc" -ne 0 ]; then dmesg | tail -80 >&2; fi; exit "$rc"'
        p = subprocess.run(argv(script, *args), input=data, capture_output=True, timeout=90)
        out = p.stdout.decode("utf-8", errors="replace")
        if p.returncode:
            raise SystemExit(f"iSH command failed ({p.returncode}): {command}\n{out}{p.stderr.decode(errors='replace')}")
        return out

    config = {
        "session_titles": False,
        "provider": "fixture",
        "providers": {"fixture": {
            "protocol": "openai-chat-completions", "base_url": base + "/v1", "auth": {"type": "none"},
            "model_metadata": {"fixture-model": {"context_window": 100000, "max_output_tokens": 10000}},
        }},
        "models": {"fixture": "fixture-model"},
    }
    run('umask 077; mkdir -p "$HOME/.spark"; cat >"$HOME/spark"; chmod 700 "$HOME/spark"', data=binary)
    run('umask 077; cat >"$SPARK_HOME/settings.json"', data=json.dumps(config).encode())
    version = run('"$HOME/spark" --version').strip()
    first = json.loads(run('cd "$HOME" && "$HOME/spark" ask --json "$1"', PROMPT))
    assert first["final_output"] == REPLY and first["session_id"], first
    session = first["session_id"]
    second = json.loads(run('cd "$HOME" && "$HOME/spark" ask --json --resume "$1" "$2"', session, PROMPT))
    assert second["final_output"] == REPLY and second["session_id"] == session, second
    saved = json.loads(run('"$HOME/spark" session "$1" --json', session))
    assert sum(turn.get("assistant") == REPLY for turn in saved["history"]) == 2, saved
    interactive(argv('cd "$HOME" && "$HOME/spark" --resume "$1"; rc=$?; if [ "$rc" -ne 0 ]; then dmesg | tail -65; fi; exit "$rc"', session))
    saved = json.loads(run('"$HOME/spark" session "$1" --json', session))
    assert sum(turn.get("assistant") == REPLY for turn in saved["history"]) == 3, saved
    upgrade = json.loads(run('SPARK_TEST_UPGRADE_BASE_URL="$1" "$HOME/spark" upgrade --json', base))
    assert upgrade.get("status") == "upgraded", upgrade
    assert run('sha256sum "$HOME/spark"').split()[0] == updated_sha
    assert run('"$HOME/spark" --version').strip() == version
    print(f"iSH x86 smoke passed: streamed Unicode, saved and resumed chat in the terminal, verified and installed an update ({version}).")


def interactive(argv):
    master, slave = pty.openpty()
    out = b""
    proc = None
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 100, 0, 0))
        proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        slave = None

        def wait_for(marker):
            nonlocal out
            ends = time.monotonic() + 35
            while marker not in out:
                if time.monotonic() >= ends or proc.poll() is not None:
                    raise SystemExit(f"iSH terminal never showed {marker!r}: {out[-4000:]!r}")
                if select.select([master], [], [], 0.2)[0]:
                    out += os.read(master, 65536)

        wait_for(b"fixture-model")
        out = b""
        # Send an ordinary iSH-style paste, splitting the emoji over reads.
        prompt = PASTED.encode()
        split = prompt.index("👋".encode()) + 2
        os.write(master, b"\x1b[200~" + prompt[:split])
        time.sleep(0.05)
        os.write(master, prompt[split:] + b"\x1b[201~")
        wait_for(b"Pasted follow-up:")
        os.write(master, b"\r")
        wait_for(b"Fixture reply:")
        wait_for(b"state=done:app=spark")
        os.write(master, b"\x04")
        ends = time.monotonic() + 10
        while time.monotonic() < ends:
            if not select.select([master], [], [], 0.2)[0]:
                if proc.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break  # A closed PTY can signal EOF as EIO on Linux.
            if not chunk:
                break
            out += chunk
        rc = proc.wait(timeout=2)
        if rc != 0:
            raise SystemExit(f"iSH terminal failed ({rc}): {out[-6000:]!r}")
    finally:
        if proc and proc.poll() is None:
            proc.kill()
            proc.wait()
        if slave is not None:
            os.close(slave)
        os.close(master)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: python3 scripts/smoke-ish.py SPARK_BINARY ISH_BINARY ALPINE_FAKEFS")
    main(*(os.path.abspath(arg) for arg in sys.argv[1:]))
