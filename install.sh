#!/bin/sh
# OpenUsage one-line installer for Linux and macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/CariSoftwareBR/OpenUsage/main/install.sh | sh
#
# Installs everything the widget needs without asking (Git and the Python GTK 3
# bindings on Linux, the Xcode Command Line Tools on macOS, and Node.js LTS when
# node is missing or older than 22.6), downloads OpenUsage, adds it to the app
# menu / ~/Applications and opens it. Idempotent: running it again updates an
# existing install. Mirrors the Install section of Installation.md. Everything
# lives in functions called on the last line, so a download cut short never runs
# a partial script.

set -u

REPO_URL="https://github.com/CariSoftwareBR/OpenUsage.git"
TARBALL_URL="https://github.com/CariSoftwareBR/OpenUsage/archive/refs/heads/main.tar.gz"
NODE_DIST="https://nodejs.org/dist/latest-v24.x"

say()  { printf '  %s\n' "$*"; }
fail() { printf '\n  [X] %s\n\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    elif have doas; then
        doas "$@"
    else
        return 1
    fi
}

download() {
    # $1 = URL, written to stdout.
    if have curl; then
        curl -fsSL "$1"
    elif have wget; then
        wget -qO- "$1"
    else
        return 1
    fi
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

node_ok() {
    have node && node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=6)?0:1)' \
        >/dev/null 2>&1 </dev/null
}

gtk_ok() {
    have python3 && python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' \
        >/dev/null 2>&1 </dev/null
}

ensure_path() {
    # Keep ~/.local/bin on the PATH of future terminals.
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) return 0 ;;
    esac
    line='export PATH="$HOME/.local/bin:$PATH"'
    added=
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
            grep -q 'HOME/.local/bin' "$rc" || printf '\n%s\n' "$line" >> "$rc"
            added=1
        fi
    done
    if [ -z "$added" ]; then
        # No rc file yet: macOS defaults to zsh, most Linux shells read .profile.
        case "${SHELL:-}" in
            */zsh) rc="$HOME/.zshrc" ;;
            *) rc="$HOME/.profile" ;;
        esac
        if [ ! -f "$rc" ] || ! grep -q 'HOME/.local/bin' "$rc"; then
            printf '\n%s\n' "$line" >> "$rc"
        fi
    fi
}

install_node() {
    # Official Node.js LTS build, checked against nodejs.org's SHA-256 list and
    # kept in $1 (no sudo needed); node, npm and npx are linked into ~/.local/bin.
    node_dir=$1
    case "$(uname -s)" in
        Darwin) os=darwin ;;
        *) os=linux ;;
    esac
    case "$(uname -m)" in
        x86_64 | amd64) arch=x64 ;;
        aarch64 | arm64) arch=arm64 ;;
        armv7l) arch=armv7l ;;
        *) fail "No Node.js build for $(uname -m). Install Node.js >= 22.6 yourself and run this installer again." ;;
    esac
    say "Node.js >= 22.6 not found: installing Node.js LTS into $node_dir..."
    line=$(download "$NODE_DIST/SHASUMS256.txt" | grep " node-v[0-9.]*-$os-$arch\.tar\.gz\$" | head -n1)
    [ -n "$line" ] || fail "Could not read the Node.js release list from nodejs.org."
    file=${line##* }
    sum=${line%% *}
    tmp=$(mktemp -d) || fail "Could not create a temporary directory."
    if ! download "$NODE_DIST/$file" > "$tmp/$file"; then
        rm -rf "$tmp"
        fail "Node.js download failed."
    fi
    if [ "$(sha256_of "$tmp/$file")" != "$sum" ]; then
        rm -rf "$tmp"
        fail "The Node.js download does not match its checksum. Try again."
    fi
    tar -xzf "$tmp/$file" -C "$tmp" || { rm -rf "$tmp"; fail "Could not unpack Node.js."; }
    mkdir -p "$(dirname "$node_dir")" || fail "Could not create $(dirname "$node_dir")."
    rm -rf "$node_dir" && mv "$tmp/${file%.tar.gz}" "$node_dir" || { rm -rf "$tmp"; fail "Could not move Node.js into $node_dir."; }
    rm -rf "$tmp"

    # This session (the widget remembers the node it was installed with)...
    PATH="$node_dir/bin:$PATH"
    export PATH
    # ...and every future terminal. Never replaces a real file of the user's.
    mkdir -p "$HOME/.local/bin"
    for b in node npm npx; do
        link="$HOME/.local/bin/$b"
        if [ ! -e "$link" ] || [ -L "$link" ]; then
            ln -sf "$node_dir/bin/$b" "$link"
        fi
    done
    ensure_path
    node_ok || fail "Installed Node.js, but '$node_dir/bin/node' does not run."
    say "[OK] Node.js $(node -v) installed."
}

install_linux_packages() {
    # Git, Python 3 and its GTK 3 bindings, from the distribution.
    say "Installing $1 (your password may be requested)..."
    if have apt-get; then
        as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null \
            && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                git python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 </dev/null
    elif have dnf; then
        as_root dnf install -y git python3 python3-gobject gtk3 </dev/null
    elif have pacman; then
        as_root pacman -Sy --noconfirm --needed git python python-gobject gtk3 </dev/null
    elif have zypper; then
        as_root zypper --non-interactive install git python3 python3-gobject python3-gobject-Gdk typelib-1_0-Gtk-3_0 </dev/null
    else
        return 1
    fi
}

install_macos_clt() {
    # Headless Command Line Tools install (same approach as Homebrew's installer):
    # provides git and swiftc without the GUI dialog.
    say "Installing the Xcode Command Line Tools (your password may be requested)..."
    flag=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    as_root touch "$flag" </dev/null || return 1
    label=$(softwareupdate -l 2>/dev/null | grep -B 1 -E 'Command Line Tools' \
        | awk -F'*' '/^ *\*/ {print $2}' | sed -e 's/^ *Label: //' -e 's/^ *//' \
        | sort -V | tail -n1)
    status=1
    if [ -n "$label" ]; then
        as_root softwareupdate -i "$label" </dev/null && status=0
    fi
    as_root rm -f "$flag" </dev/null
    return $status
}

looks_like_openusage() {
    # Only a folder that is empty or holds OpenUsage may be replaced.
    [ -f "$1/scripts/usage-json.ts" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

get_code() {
    dir=$1
    if [ -d "$dir/.git" ] && have git; then
        say "Updating $dir (git pull)..."
        git -C "$dir" pull --ff-only --quiet </dev/null \
            || fail "git pull failed in $dir. Check 'git -C \"$dir\" status' and try again."
    elif have git; then
        # A copy from an earlier download without Git is replaced by a clone,
        # so Settings -> Update now works from now on.
        if [ -e "$dir" ]; then
            looks_like_openusage "$dir" || fail "$dir exists and is not OpenUsage. Move it away and try again."
            rm -rf "$dir" || fail "Could not replace $dir."
        fi
        say "Cloning OpenUsage into $dir..."
        mkdir -p "$(dirname "$dir")"
        git clone --quiet "$REPO_URL" "$dir" </dev/null || fail "git clone failed."
    else
        # No Git: plain download. Run this installer again to update.
        if [ -e "$dir" ]; then
            looks_like_openusage "$dir" || fail "$dir exists and is not OpenUsage. Move it away and try again."
        fi
        say "Downloading OpenUsage into $dir..."
        tmp=$(mktemp -d) || fail "Could not create a temporary directory."
        if ! download "$TARBALL_URL" | tar -xz -C "$tmp"; then
            rm -rf "$tmp"
            fail "Download failed. Install curl or wget (or git) and try again."
        fi
        [ -f "$tmp/OpenUsage-main/scripts/usage-json.ts" ] || { rm -rf "$tmp"; fail "Downloaded archive is incomplete."; }
        mkdir -p "$(dirname "$dir")"
        rm -rf "$dir" && mv "$tmp/OpenUsage-main" "$dir" || { rm -rf "$tmp"; fail "Could not move files into $dir."; }
        rm -rf "$tmp"
    fi
    chmod +x "$dir/widget-linux/install.sh" "$dir/widget-mac/build.sh" 2>/dev/null
}

main_linux() {
    dir="$HOME/.local/share/OpenUsage"

    if ! have git || ! gtk_ok; then
        install_linux_packages "Git and the Python GTK 3 bindings"
        hash -r 2>/dev/null
        gtk_ok || fail "Could not install the Python GTK 3 bindings automatically.
      Debian/Ubuntu/Mint/Zorin: sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0
      Fedora:                   sudo dnf install python3-gobject gtk3
      Arch:                     sudo pacman -S python-gobject gtk3
      Then run this installer again."
        say "[OK] Python GTK 3 bindings ready."
    fi

    node_ok || install_node "$HOME/.local/share/OpenUsage-node"

    # An open widget keeps running the old version.
    pkill -f 'widget-linux/openusage.py' 2>/dev/null || true
    get_code "$dir"

    open=
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        "$dir/widget-linux/install.sh" </dev/null || fail "widget-linux/install.sh failed."
        open=1
    else
        "$dir/widget-linux/install.sh" --no-open </dev/null || fail "widget-linux/install.sh failed."
    fi

    printf '\n'
    say "[OK] OpenUsage $(version "$dir") installed in $dir"
    if [ -n "$open" ]; then
        say "The widget is open. Next time, open OpenUsage from the app menu."
    else
        say "No desktop session here: open OpenUsage from the app menu once you are in one."
    fi
}

main_macos() {
    dir="$HOME/Library/Application Support/OpenUsage"

    # /usr/bin/git and swiftc are stubs until the Command Line Tools are installed:
    # never run them before that.
    if ! xcode-select -p >/dev/null 2>&1 || ! have swiftc; then
        if ! install_macos_clt || ! xcode-select -p >/dev/null 2>&1; then
            xcode-select --install >/dev/null 2>&1 || true
            fail "Could not install the Xcode Command Line Tools automatically.
      Finish the installer that just opened (or run: xcode-select --install),
      then run this installer again."
        fi
        say "[OK] Xcode Command Line Tools installed."
    fi

    node_ok || install_node "$HOME/Library/Application Support/OpenUsage-node"

    get_code "$dir"

    # Compiles ~/Applications/OpenUsage.app (closing a running copy) and opens it.
    "$dir/widget-mac/build.sh" </dev/null || fail "Building OpenUsage.app failed."
    open "$HOME/Applications/OpenUsage.app" || true

    printf '\n'
    say "[OK] OpenUsage $(version "$dir") installed in ~/Applications/OpenUsage.app"
    say "The widget is in the menu bar. Next time, open OpenUsage from Spotlight or Launchpad."
    say "If macOS asks whether 'security' can read 'Claude Code-credentials', click Always Allow."
}

version() {
    sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$1/package.json" 2>/dev/null | head -n1
}

main() {
    printf '\n  OpenUsage installer\n\n'
    case "$(uname -s)" in
        Linux) main_linux ;;
        Darwin) main_macos ;;
        *) fail "This installer is for Linux and macOS. On Windows, run in PowerShell:
      irm https://raw.githubusercontent.com/CariSoftwareBR/OpenUsage/main/install.ps1 | iex" ;;
    esac
    if [ -d "$dir/.git" ]; then
        say "Settings -> Update now keeps it current (or run this command again)."
    else
        say "Installed without Git: run this command again to update."
    fi
    printf '\n'
}

main "$@"
