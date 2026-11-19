#!/bin/sh
# spark installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/NZ-Linix/spark/main/install.sh | sh
#
# Pass options after `sh -s --` when piping:
#
#   curl -fsSL .../install.sh | sh -s -- --version v26.11.19
#
# Options:
#   --version <tag>     Install this release instead of the latest
#   --dir <path>        Install into <path> (default: ~/.local/bin)
#   --from-source       Build from source with git and zig
#   --archive <file>    Install from a local release archive
#   --yes               Answer yes to every question
#   --no-modify-path    Never edit a shell profile
#   --no-animation      Plain output
#   --uninstall         Remove spark from the install directory
#   -h, --help          Show this help
#
# Environment: SPARK_REPO, SPARK_VERSION, SPARK_INSTALL_DIR,
# GITHUB_TOKEN or GH_TOKEN (for a private repository), NO_COLOR.

set -eu

REPO=${SPARK_REPO:-NZ-Linix/spark}
VERSION=${SPARK_VERSION:-latest}
INSTALL_DIR=${SPARK_INSTALL_DIR:-$HOME/.local/bin}
FROM_SOURCE=0
ARCHIVE=""
ASSUME_YES=0
MODIFY_PATH=1
ANIMATE=1
UNINSTALL=0

usage() {
	cat <<'EOF'
spark installer for macOS and Linux.

  curl -fsSL https://raw.githubusercontent.com/NZ-Linix/spark/main/install.sh | sh
  curl -fsSL .../install.sh | sh -s -- [options]

Options:
  --version <tag>     Install this release instead of the latest
  --dir <path>        Install into <path> (default: ~/.local/bin)
  --from-source       Build from source with git and zig
  --archive <file>    Install from a local release archive
  --yes               Answer yes to every question
  --no-modify-path    Never edit a shell profile
  --no-animation      Plain output
  --uninstall         Remove spark from the install directory
  -h, --help          Show this help

Environment: SPARK_REPO, SPARK_VERSION, SPARK_INSTALL_DIR,
GITHUB_TOKEN or GH_TOKEN (for a private repository), NO_COLOR.
EOF
}

die_early() {
	printf 'spark installer: %s\n' "$1" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case $1 in
	--version) [ $# -ge 2 ] || die_early "--version needs a tag"; VERSION=$2; shift ;;
	--version=*) VERSION=${1#*=} ;;
	--dir) [ $# -ge 2 ] || die_early "--dir needs a path"; INSTALL_DIR=$2; shift ;;
	--dir=*) INSTALL_DIR=${1#*=} ;;
	--from-source) FROM_SOURCE=1 ;;
	--archive) [ $# -ge 2 ] || die_early "--archive needs a file"; ARCHIVE=$2; shift ;;
	--archive=*) ARCHIVE=${1#*=} ;;
	--yes | -y) ASSUME_YES=1 ;;
	--no-modify-path) MODIFY_PATH=0 ;;
	--no-animation) ANIMATE=0 ;;
	--uninstall) UNINSTALL=1 ;;
	-h | --help) usage; exit 0 ;;
	*) die_early "unknown option: $1 (see --help)" ;;
	esac
	shift
done

case $VERSION in
latest | v*) ;;
*) VERSION="v$VERSION" ;;
esac
case $INSTALL_DIR in
"~"/*) INSTALL_DIR="$HOME/${INSTALL_DIR#"~/"}" ;;
esac

# ── terminal ──────────────────────────────────────────────────────────────

TTY=0
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${CI:-}" ]; then TTY=1; fi
[ "$TTY" = 1 ] || ANIMATE=0

ESC=$(printf '\033')
if [ "$TTY" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
	R="${ESC}[0m"
	BRIGHT="${ESC}[1;97m"
	WHITE="${ESC}[0;37m"
	GRAY="${ESC}[38;5;245m"
	FAINT="${ESC}[38;5;240m"
	RED="${ESC}[1;31m"
	YELLOW="${ESC}[33m"
else
	R="" BRIGHT="" WHITE="" GRAY="" FAINT="" RED="" YELLOW=""
fi
CLEAR_LINE="${ESC}[2K"
[ "$TTY" = 1 ] || CLEAR_LINE=""

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
*UTF-8* | *utf-8* | *UTF8* | *utf8*) UTF8=1 ;;
*) UTF8=0 ;;
esac
if [ "$UTF8" = 1 ]; then
	STAR="✦" TWINKLE="✧" DOT="·" CHECK="✓" CROSS="✗" ARROW="→"
else
	STAR="*" TWINKLE="+" DOT="." CHECK="+" CROSS="x" ARROW="->"
fi

TMP=""
cleanup() {
	[ "$TTY" = 1 ] && printf '%s[?25h' "$ESC"
	[ -n "$TMP" ] && rm -rf "$TMP"
	return 0
}
trap cleanup EXIT
trap 'cleanup; printf "\n"; exit 130' INT TERM

pause() {
	[ "$ANIMATE" = 1 ] && sleep "$1"
	return 0
}

# shellcheck disable=SC2088 # prints a literal ~ for display
tilde() {
	case $1 in
	"$HOME") printf '~' ;;
	"$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
	*) printf '%s' "$1" ;;
	esac
}

say() { printf '  %s\n' "$*"; }
note() { printf '     %s%s%s\n' "$GRAY" "$*" "$R"; }

warn() {
	printf '  %s!%s  %s\n' "$YELLOW" "$R" "$*"
}

fail() {
	printf '\n  %s%s%s  %s\n' "$RED" "$CROSS" "$R" "$1"
	shift
	for line in "$@"; do note "$line"; done
	printf '\n'
	exit 1
}

# streak WIDTH HEAD SEED: a field of faint dots WIDTH wide with the comet's
# head at column HEAD, its tail behind it, and a few dots twinkling.
streak() {
	c=0
	out=""
	while [ $c -lt "$1" ]; do
		if [ $c -eq "$2" ]; then
			out="$out$BRIGHT$STAR"
		elif [ $c -eq $(($2 - 1)) ]; then
			out="$out$WHITE="
		elif [ $c -eq $(($2 - 2)) ]; then
			out="$out$GRAY-"
		elif [ $(((c * 7 + $3) % 11)) -eq 0 ]; then
			out="$out$GRAY$TWINKLE"
		else
			out="$out$FAINT$DOT"
		fi
		c=$((c + 1))
	done
	printf '%s%s' "$out" "$R"
}

# One spinner frame: the comet loops through a 14-column field.
comet() {
	streak 14 $(($1 % 18)) $(($1 / 3))
}

# sweep WIDTH: the comet crosses an empty line once, then the line clears.
sweep() {
	[ "$ANIMATE" = 1 ] || return 0
	printf '%s[?25l' "$ESC"
	head=0
	while [ $head -le $(($1 + 2)) ]; do
		printf '\r%s  ' "$CLEAR_LINE"
		streak "$1" "$head" "$head"
		head=$((head + 1))
		sleep 0.012
	done
	printf '\r%s%s[?25h' "$CLEAR_LINE" "$ESC"
}

# run_step LABEL COMMAND...: runs COMMAND with a comet beside LABEL, then
# leaves a check mark and the detail the command wrote to $TMP/detail.
run_step() {
	label=$1
	shift
	: >"$TMP/log"
	: >"$TMP/detail"
	if [ "$ANIMATE" = 1 ]; then
		printf '%s[?25l' "$ESC"
		"$@" >>"$TMP/log" 2>&1 &
		pid=$!
		tick=0
		start=$(date +%s)
		elapsed=""
		while kill -0 "$pid" 2>/dev/null; do
			if [ $((tick % 15)) -eq 0 ]; then
				secs=$(($(date +%s) - start))
				if [ "$secs" -ge 3 ]; then elapsed="${secs}s"; fi
			fi
			printf '\r%s  %s%s%s  %s  ' "$CLEAR_LINE" "$GRAY" "$STAR" "$R" "$label"
			comet "$tick"
			[ -n "$elapsed" ] && printf '  %s%s%s' "$GRAY" "$elapsed" "$R"
			tick=$((tick + 1))
			sleep 0.05
		done
		set +e
		wait "$pid"
		status=$?
		set -e
		printf '\r%s%s[?25h' "$CLEAR_LINE" "$ESC"
	else
		set +e
		(
			set -e
			"$@"
		) >>"$TMP/log" 2>&1
		status=$?
		set -e
	fi
	detail=$(cat "$TMP/detail" 2>/dev/null || true)
	if [ "$status" -ne 0 ]; then
		printf '  %s%s%s  %s\n' "$RED" "$CROSS" "$R" "$label"
		reason=$(tail -n 1 "$TMP/reason" 2>/dev/null || true)
		[ -n "$reason" ] && printf '\n  %s\n' "$reason"
		if [ -z "$reason" ] && [ -s "$TMP/log" ]; then
			printf '\n'
			tail -n 12 "$TMP/log" | while IFS= read -r line; do note "$line"; done
		fi
		printf '\n'
		exit 1
	fi
	if [ -n "$detail" ]; then
		printf '  %s%s%s  %s  %s%s%s\n' "$BRIGHT" "$CHECK" "$R" "$label" "$GRAY" "$detail" "$R"
	else
		printf '  %s%s%s  %s\n' "$BRIGHT" "$CHECK" "$R" "$label"
	fi
}

# Inside a step: record why it failed, shown under the step.
reason() {
	printf '%s\n' "$1" >>"$TMP/reason"
	return 1
}

LOGO='                      _
 ___ _ __   __ _ _ __| | __
/ __| '"'"'_ \ / _` | '"'"'__| |/ /
\__ \ |_) | (_| | |  |   <
|___/ .__/ \__,_|_|  |_|\_\
    |_|'

header() {
	# install.ps1 has drawn the header already when it runs this in WSL.
	[ "${SPARK_INSTALLER_NESTED:-}" = 1 ] && return 0
	printf '\n'
	if [ "$ANIMATE" = 1 ]; then printf '%s[?25l' "$ESC"; fi
	printf '%s\n' "$LOGO" | while IFS= read -r line; do
		printf '  %s%s%s\n' "$BRIGHT" "$line" "$R"
		pause 0.04
	done
	# The comet streaks under the logo, and the mark settles in its place.
	sweep 27
	printf '  %s-=%s%s%s %sinstaller%s\n\n' "$WHITE" "$BRIGHT" "$STAR" "$R" "$GRAY" "$R"
}

finale() {
	sweep 27
	printf '  %s-=%s%s%s %sspark %s is ready.%s\n' "$WHITE" "$BRIGHT" "$STAR" "$R" "$BRIGHT" "$1" "$R"
}

# ── helpers ───────────────────────────────────────────────────────────────

TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-}}

need() {
	command -v "$1" >/dev/null 2>&1
}

# http_get URL OUT [ACCEPT]: the token, when there is one, goes to curl on
# stdin so it never shows in the process list.
http_get() {
	if [ -n "$TOKEN" ]; then
		{
			printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
			[ -n "${3:-}" ] && printf 'header = "Accept: %s"\n' "$3"
			true
		} | curl -fsSL --retry 2 --connect-timeout 15 -K - -o "$2" "$1"
	elif [ -n "${3:-}" ]; then
		curl -fsSL --retry 2 --connect-timeout 15 -H "Accept: $3" -o "$2" "$1"
	else
		curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1"
	fi
}

human_size() {
	awk -v b="$1" 'BEGIN {
		if (b >= 1048576) printf "%.1f MB", b / 1048576
		else if (b >= 1024) printf "%.0f KB", b / 1024
		else printf "%d B", b }'
}

sha256_of() {
	if need sha256sum; then
		sha256sum "$1" | awk '{print $1}'
	elif need shasum; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		return 1
	fi
}

json_field() { # FILE KEY: the first string value of KEY
	tr ',' '\n' <"$1" | sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# The API URL of release asset NAME in release JSON FILE.
asset_api_url() {
	tr ',{}' '\n\n\n' <"$1" | awk -v name="$2" '
		/"url": *"https:\/\/api\.github\.com\/repos\/.*\/releases\/assets\/[0-9]+"/ {
			match($0, /https:[^"]+/); url = substr($0, RSTART, RLENGTH)
		}
		/"name": *"/ { if (index($0, "\"" name "\"")) { print url; exit } }'
}

# ── platform ──────────────────────────────────────────────────────────────

detect_platform() {
	os=$(uname -s)
	arch=$(uname -m)
	case $os in
	Darwin) OS=macos OS_NAME=macOS ;;
	Linux) OS=linux OS_NAME=Linux ;;
	MINGW* | MSYS* | CYGWIN*)
		fail "spark runs on macOS and Linux." \
			"On Windows, install it inside WSL. In PowerShell run:" \
			"irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex" ;;
	*) fail "spark has no build for $os." "It runs on macOS and Linux." ;;
	esac
	case $arch in
	x86_64 | amd64) ARCH=x86_64 ;;
	arm64 | aarch64) ARCH=aarch64 ;;
	*) fail "spark has no build for $arch processors." "Try building from source with --from-source." ;;
	esac
	# An Intel shell under Rosetta still gets the native Apple silicon build.
	if [ "$OS" = macos ] && [ "$ARCH" = x86_64 ] &&
		[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
		ARCH=aarch64
	fi
	ASSET="spark-$OS-$ARCH.tar.gz"
	case $ARCH in aarch64) ARCH_NAME=arm64 ;; *) ARCH_NAME=$ARCH ;; esac
}

# ── steps ─────────────────────────────────────────────────────────────────

step_find_release() {
	if [ "$VERSION" = latest ]; then
		api="https://api.github.com/repos/$REPO/releases/latest"
	else
		api="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
	fi
	if ! http_get "$api" "$TMP/release.json" "application/vnd.github+json"; then
		if [ -z "$TOKEN" ]; then
			reason "No release found for $REPO. If the repository is private, set GITHUB_TOKEN or sign in with gh."
		elif [ "$VERSION" = latest ]; then
			reason "$REPO has no published release yet. Try --from-source."
		else
			reason "There is no release $VERSION in $REPO."
		fi
	fi
	tag=$(json_field "$TMP/release.json" tag_name)
	[ -n "$tag" ] || reason "The release had no tag."
	printf '%s' "$tag" >"$TMP/tag"
	if ! grep -q "\"$ASSET\"" "$TMP/release.json"; then
		reason "Release $tag has no build for $OS_NAME $ARCH_NAME. Try --from-source."
	fi
	printf '%s' "$tag" >"$TMP/detail"
}

step_download() {
	if [ -n "$TOKEN" ]; then
		url=$(asset_api_url "$TMP/release.json" "$ASSET")
		sum_url=$(asset_api_url "$TMP/release.json" "$ASSET.sha256")
		[ -n "$url" ] || reason "Could not find $ASSET in the release."
		http_get "$url" "$TMP/$ASSET" application/octet-stream || reason "The download failed."
		if [ -n "$sum_url" ]; then
			http_get "$sum_url" "$TMP/$ASSET.sha256" application/octet-stream || true
		fi
	else
		base="https://github.com/$REPO/releases/download/$TAG"
		http_get "$base/$ASSET" "$TMP/$ASSET" || reason "The download failed."
		http_get "$base/$ASSET.sha256" "$TMP/$ASSET.sha256" || true
	fi
	human_size "$(wc -c <"$TMP/$ASSET" | tr -d ' ')" >"$TMP/detail"
}

step_verify() {
	[ -s "$TMP/$ASSET.sha256" ] || reason "The release has no checksum for $ASSET, so spark won't install it."
	want=$(awk '{print $1; exit}' "$TMP/$ASSET.sha256")
	have=$(sha256_of "$TMP/$ASSET") || reason "Neither sha256sum nor shasum is installed."
	[ "$want" = "$have" ] || reason "The checksum does not match. The download may be damaged; try again."
	printf 'sha256 %s' "$(printf '%s' "$have" | cut -c1-12)" >"$TMP/detail"
}

step_unpack() {
	mkdir -p "$TMP/unpack"
	tar -xzf "$1" -C "$TMP/unpack" || reason "Could not unpack the archive."
	bin=$(find "$TMP/unpack" -type f -name spark | head -n 1)
	[ -n "$bin" ] || reason "The archive has no spark binary."
	chmod 755 "$bin"
	"$bin" --version >"$TMP/new_version" 2>&1 || reason "The downloaded spark does not run on this machine."
	printf '%s' "$bin" >"$TMP/bin"
}

step_clone() {
	need git || reason "Building from source needs git."
	if [ "$VERSION" = latest ]; then set -- --depth 1; else set -- --depth 1 --branch "$VERSION"; fi
	if need gh && gh auth status >/dev/null 2>&1; then
		gh repo clone "$REPO" "$TMP/src" -- "$@" || reason "Could not clone $REPO."
	else
		git clone "$@" "https://github.com/$REPO.git" "$TMP/src" ||
			reason "Could not clone $REPO. If it is private, sign in with gh first."
	fi
	git -C "$TMP/src" rev-parse --short HEAD >"$TMP/detail"
}

step_build() {
	(cd "$TMP/src" && zig build -Doptimize=ReleaseSafe) || reason "The build failed."
	printf '%s' "$TMP/src/zig-out/bin/spark" >"$TMP/bin"
	"$TMP/src/zig-out/bin/spark" --version >"$TMP/new_version" 2>&1 || reason "The built spark does not run."
	printf 'ReleaseSafe' >"$TMP/detail"
}

step_install() {
	mkdir -p "$INSTALL_DIR" || reason "Could not create $INSTALL_DIR."
	staged="$INSTALL_DIR/.spark.install.$$"
	cp "$(cat "$TMP/bin")" "$staged" || reason "Could not write to $INSTALL_DIR."
	chmod 755 "$staged"
	mv -f "$staged" "$INSTALL_DIR/spark" || {
		rm -f "$staged"
		reason "Could not replace $INSTALL_DIR/spark."
	}
	tilde "$INSTALL_DIR/spark" >"$TMP/detail"
}

check_zig() {
	need zig || fail "Building from source needs Zig 0.17.1 or newer." "Get it from https://ziglang.org/download/"
	zv=$(zig version 2>/dev/null || echo 0)
	major=$(printf '%s' "$zv" | cut -d. -f1)
	minor=$(printf '%s' "$zv" | cut -d. -f2)
	if [ "${major:-0}" -eq 0 ] && [ "${minor:-0}" -lt 17 ] 2>/dev/null; then
		fail "Building from source needs Zig 0.17.1 or newer; this machine has $zv." \
			"Get it from https://ziglang.org/download/"
	fi
}

# ── PATH ──────────────────────────────────────────────────────────────────

on_path() {
	case ":$PATH:" in *":$1:"*) return 0 ;; esac
	return 1
}

profile_for_shell() {
	case $(basename "${SHELL:-sh}") in
	zsh) printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
	bash) if [ "$OS" = macos ]; then printf '%s' "$HOME/.bash_profile"; else printf '%s' "$HOME/.bashrc"; fi ;;
	fish) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
	*) printf '%s' "$HOME/.profile" ;;
	esac
}

# shellcheck disable=SC2016 # $PATH stays literal in the profile line
path_line() {
	dir=$(tilde "$1")
	case $dir in "~"*) dir="\$HOME${dir#"~"}" ;; esac
	case $2 in
	*config.fish) printf 'fish_add_path "%s"' "$dir" ;;
	*) printf 'export PATH="%s:$PATH"' "$dir" ;;
	esac
}

# ask QUESTION: yes or no from the terminal, even when the script itself
# arrives on stdin through a pipe. No terminal means no.
ask() {
	[ "$ASSUME_YES" = 1 ] && return 0
	[ -r /dev/tty ] && [ "$TTY" = 1 ] || return 1
	printf '  %s?%s  %s %s[Y/n]%s ' "$BRIGHT" "$R" "$1" "$GRAY" "$R"
	answer=""
	IFS= read -r answer </dev/tty || answer=n
	case $answer in "" | y | Y | yes | YES) return 0 ;; esac
	return 1
}

PATH_HINT=""
setup_path() {
	on_path "$INSTALL_DIR" && return 0
	profile=$(profile_for_shell)
	line=$(path_line "$INSTALL_DIR" "$profile")
	if [ "$MODIFY_PATH" = 1 ] && [ -f "$profile" ] && grep -Fq "$line" "$profile"; then
		PATH_HINT="Open a new terminal so $(tilde "$INSTALL_DIR") is on your PATH."
		return 0
	fi
	if [ "$MODIFY_PATH" = 1 ] && ask "Add $(tilde "$INSTALL_DIR") to your PATH in $(tilde "$profile")?"; then
		mkdir -p "$(dirname "$profile")"
		printf '\n# Added by the spark installer\n%s\n' "$line" >>"$profile"
		printf '  %s%s%s  Added to PATH  %s%s%s\n' "$BRIGHT" "$CHECK" "$R" "$GRAY" "$(tilde "$profile")" "$R"
		PATH_HINT="Open a new terminal, or run: $line"
	else
		PATH_HINT="Add $(tilde "$INSTALL_DIR") to your PATH: $line"
	fi
}

# ── main ──────────────────────────────────────────────────────────────────

main() {
	need curl || [ -n "$ARCHIVE" ] || [ "$UNINSTALL" = 1 ] || die_early "curl is required"
	TMP=$(mktemp -d 2>/dev/null || mktemp -d -t spark-install)

	header
	detect_platform

	if [ "$UNINSTALL" = 1 ]; then
		if [ -e "$INSTALL_DIR/spark" ]; then
			rm -f "$INSTALL_DIR/spark"
			printf '  %s%s%s  Removed %s\n' "$BRIGHT" "$CHECK" "$R" "$(tilde "$INSTALL_DIR/spark")"
			note "Your settings and sessions in ~/.spark are still there."
		else
			say "spark is not installed in $(tilde "$INSTALL_DIR")."
		fi
		printf '\n'
		return 0
	fi

	OLD_VERSION=""
	if [ -x "$INSTALL_DIR/spark" ]; then
		OLD_VERSION=$("$INSTALL_DIR/spark" --version 2>/dev/null | head -n 1 || true)
	fi

	printf '  %s%s%s  %s %s  %s%s%s\n' "$BRIGHT" "$CHECK" "$R" "$OS_NAME" "$ARCH_NAME" "$GRAY" "$(tilde "$INSTALL_DIR")" "$R"
	pause 0.08

	if [ -n "$ARCHIVE" ]; then
		[ -f "$ARCHIVE" ] || fail "No archive at $ARCHIVE."
		run_step "Unpacking $(basename "$ARCHIVE")" step_unpack "$ARCHIVE"
	elif [ "$FROM_SOURCE" = 1 ]; then
		check_zig
		run_step "Cloning $REPO" step_clone
		run_step "Building spark" step_build
	else
		# A private repository answers 404 without a token; a signed-in gh
		# has one.
		if [ -z "$TOKEN" ] && need gh &&
			! curl -fsS -o /dev/null --connect-timeout 10 "https://api.github.com/repos/$REPO" 2>/dev/null; then
			TOKEN=$(gh auth token 2>/dev/null || true)
		fi
		run_step "Finding the release" step_find_release
		TAG=$(cat "$TMP/tag")
		run_step "Downloading $ASSET" step_download
		run_step "Verifying the checksum" step_verify
		run_step "Unpacking" step_unpack "$TMP/$ASSET"
	fi

	run_step "Installing" step_install
	NEW_VERSION=$(head -n 1 "$TMP/new_version")
	setup_path

	other=$(command -v spark 2>/dev/null || true)
	if [ -n "$other" ] && [ "$other" != "$INSTALL_DIR/spark" ]; then
		warn "Another spark comes first on your PATH: $(tilde "$other")"
	fi

	printf '\n'
	finale "v${NEW_VERSION#v}"
	if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
		note "Updated from v${OLD_VERSION#v} $ARROW v${NEW_VERSION#v}"
	fi
	printf '\n'
	printf '  %sStart%s         spark\n' "$GRAY" "$R"
	printf '  %sAdd a model%s   /connect %sinside spark%s\n' "$GRAY" "$R" "$GRAY" "$R"
	printf '  %sUpdate%s        run this installer again\n' "$GRAY" "$R"
	if [ -n "$PATH_HINT" ]; then
		printf '\n'
		note "$PATH_HINT"
	fi
	printf '\n'
}

main
