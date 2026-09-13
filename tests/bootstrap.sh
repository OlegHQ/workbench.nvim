#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEPS="$ROOT/.test-deps"
MINI="$DEPS/mini.test"
MINI_COMMIT=4c70379d07ea44f697d96c7a6f04c79f17b34bb3
NVIM_VERSION=0.11.7

mkdir -p "$DEPS"

if [ ! -d "$MINI/.git" ]; then
  git clone https://github.com/nvim-mini/mini.test.git "$MINI"
  git -C "$MINI" checkout --detach "$MINI_COMMIT"
else
  actual=$(git -C "$MINI" rev-parse HEAD)
  if [ "$actual" != "$MINI_COMMIT" ]; then
    echo "mini.test at $MINI is $actual; expected pinned commit $MINI_COMMIT" >&2
    exit 1
  fi
  if ! git -C "$MINI" diff --quiet || ! git -C "$MINI" diff --cached --quiet; then
    echo "mini.test dependency has local changes: $MINI" >&2
    exit 1
  fi
fi

if [ ! -x "$DEPS/venv/bin/python" ]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3 "$DEPS/venv"
  else
    python3 -m venv "$DEPS/venv"
  fi
fi
"$DEPS/venv/bin/python" -c 'import sys; assert sys.version_info >= (3, 10), "workbench test tools require Python 3.10+"'
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$DEPS/venv/bin/python" -r "$ROOT/tests/requirements-dev.txt"
else
  "$DEPS/venv/bin/python" -m pip install -r "$ROOT/tests/requirements-dev.txt"
fi

if [ ! -x "$DEPS/neovim-$NVIM_VERSION/bin/nvim" ]; then
  system=$(uname -s)
  machine=$(uname -m)
  case "$system-$machine" in
    Darwin-arm64|Darwin-aarch64)
      archive=nvim-macos-arm64.tar.gz
      digest=9c84686ce84bbab725ff3d88ca3ac1d6da5a72128b68d9dd8094e34d4049a126
      ;;
    Darwin-x86_64|Darwin-amd64)
      archive=nvim-macos-x86_64.tar.gz
      digest=014649c0c75e188fd70d40f787ee7cb83e7c2926264cd4e72c300d0198922371
      ;;
    Linux-aarch64|Linux-arm64)
      archive=nvim-linux-arm64.tar.gz
      digest=99bb3c53604e83ce18fc0b459e34cf1a5e212f4e5fbe2eb136b3c18092ae9905
      ;;
    Linux-x86_64|Linux-amd64)
      archive=nvim-linux-x86_64.tar.gz
      digest=38a7c6317f94503841096c00e8fde05ef04b9472fc9d7d62b6e033cecd6f7991
      ;;
    *)
      echo "No pinned Neovim $NVIM_VERSION archive for $system-$machine" >&2
      exit 1
      ;;
  esac

  temp=$(mktemp -d "$DEPS/nvim-install.XXXXXX")
  trap 'rm -rf "$temp"' EXIT HUP INT TERM
  curl -fsSL "https://github.com/neovim/neovim/releases/download/v$NVIM_VERSION/$archive" -o "$temp/$archive"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s  %s\n' "$digest" "$temp/$archive" | shasum -a 256 -c -
  else
    printf '%s  %s\n' "$digest" "$temp/$archive" | sha256sum -c -
  fi
  tar -xzf "$temp/$archive" -C "$temp"
  extracted="$temp/${archive%.tar.gz}"
  mv "$extracted" "$DEPS/neovim-$NVIM_VERSION"
fi

minimum_version=$("$DEPS/neovim-$NVIM_VERSION/bin/nvim" --version | sed -n '1p')
case "$minimum_version" in
  *"v$NVIM_VERSION"*) ;;
  *) echo "minimum Neovim binary mismatch: expected $NVIM_VERSION, got $minimum_version" >&2; exit 1 ;;
esac
printf '%s\n' "$minimum_version"
"$DEPS/venv/bin/python" -c 'import msgpack, pynvim; print("pynvim", pynvim.__version__, "msgpack", msgpack.__version__)'
