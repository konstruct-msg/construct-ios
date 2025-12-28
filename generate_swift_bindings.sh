#!/bin/bash

# Generate Swift bindings using uniffi from the compiled library

set -e

echo "Building Rust library..."
cd packages/core
cargo build --lib --target aarch64-apple-ios-sim --release

echo "Generating Swift bindings..."
cd ../..

# Use cargo to run the uniffi bindgen through the library
cargo run --manifest-path packages/core/Cargo.toml --features=uniffi/cli --bin uniffi-bindgen -- \
    generate packages/core/src/construct_core.udl \
    --language swift \
    --out-dir ConstructMessenger/

echo "Swift bindings generated successfully in ConstructMessenger/"
echo "Files created:"
ls -lh ConstructMessenger/construct_core*.swift ConstructMessenger/construct_core*.h 2>/dev/null || echo "Warning: Generated files not found"
