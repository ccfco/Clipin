#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$PROJECT_ROOT/rust"
GENERATED_DIR="$PROJECT_ROOT/Clipin/Generated"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"

if command -v rustup >/dev/null 2>&1; then
    TOOLCHAIN_RUSTC="$(rustup which --toolchain "$TOOLCHAIN" rustc)"
    TOOLCHAIN_CARGO="$(rustup which --toolchain "$TOOLCHAIN" cargo)"
    TOOLCHAIN_RUSTDOC="$(rustup which --toolchain "$TOOLCHAIN" rustdoc)"
    TOOLCHAIN_BIN="$(dirname "$TOOLCHAIN_RUSTC")"
    CARGO=("$TOOLCHAIN_CARGO")
    RUSTC=("$TOOLCHAIN_RUSTC")
else
    echo "❌ rustup is required so Rust builds use the repository toolchain consistently."
    exit 1
fi

export RUSTUP_TOOLCHAIN="$TOOLCHAIN"
export RUSTC="$TOOLCHAIN_RUSTC"
export RUSTDOC="$TOOLCHAIN_RUSTDOC"
export PATH="$TOOLCHAIN_BIN:$PATH"

echo "🦀 Rust toolchain: $("${RUSTC[@]}" -V)"
echo "🎯 macOS deployment target: $MACOSX_DEPLOYMENT_TARGET"

echo "🔨 Building Rust core..."
cd "$RUST_DIR"
"${CARGO[@]}" build --release

echo "🔗 Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"
"${CARGO[@]}" run --release --bin uniffi-bindgen -- generate \
  --library "$RUST_DIR/target/release/libclipin_core.a" \
  --language swift \
  --out-dir "$GENERATED_DIR"

echo "✅ Build complete"
