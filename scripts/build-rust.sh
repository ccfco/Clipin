#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$PROJECT_ROOT/rust"
GENERATED_DIR="$PROJECT_ROOT/Clipin/Generated"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

echo "🔨 Building Rust core..."
cd "$RUST_DIR"
cargo build --release

echo "🔗 Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"
cargo run --release --bin uniffi-bindgen -- generate \
  --library "$RUST_DIR/target/release/libclipin_core.a" \
  --language swift \
  --out-dir "$GENERATED_DIR"

echo "✅ Build complete"
