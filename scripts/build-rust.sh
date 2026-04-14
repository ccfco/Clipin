#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$PROJECT_ROOT/rust"
GENERATED_DIR="$PROJECT_ROOT/Clipin/Generated"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
case "$(uname -m)" in
    arm64)
        RUST_TARGET="${RUST_TARGET:-aarch64-apple-darwin}"
        ;;
    x86_64)
        RUST_TARGET="${RUST_TARGET:-x86_64-apple-darwin}"
        ;;
    *)
        echo "❌ Unsupported macOS architecture: $(uname -m)"
        exit 1
        ;;
esac

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
echo "🎯 Rust target: $RUST_TARGET"

if ! rustup target list --toolchain "$TOOLCHAIN" --installed | grep -qx "$RUST_TARGET"; then
    echo "📦 Installing Rust target: $RUST_TARGET"
    rustup target add --toolchain "$TOOLCHAIN" "$RUST_TARGET"
fi

echo "🔨 Building Rust core..."
cd "$RUST_DIR"
"${CARGO[@]}" build --release --target "$RUST_TARGET"

TARGET_RELEASE_DIR="$RUST_DIR/target/$RUST_TARGET/release"
TARGET_LIBRARY="$TARGET_RELEASE_DIR/libclipin_core.a"
LEGACY_RELEASE_DIR="$RUST_DIR/target/release"
LEGACY_LIBRARY="$LEGACY_RELEASE_DIR/libclipin_core.a"

mkdir -p "$LEGACY_RELEASE_DIR"
cp "$TARGET_LIBRARY" "$LEGACY_LIBRARY"

echo "🔗 Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"
"${CARGO[@]}" run --release --bin uniffi-bindgen -- generate \
  --library "$TARGET_LIBRARY" \
  --language swift \
  --out-dir "$GENERATED_DIR"

echo "✅ Build complete"
