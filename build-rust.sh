#!/bin/bash
# Builds the SideInstaller Rust FFI for iOS (device + Apple-Silicon simulator)
# and repackages SideInstallerFFI.xcframework. Run whenever rust-core/ changes,
# then regenerate the project with `xcodegen generate`.
#
# Adapted from StephenDev0/StikPair's build-rust.sh.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
# Match the app's deployment floor so cc-rs (aws-lc-sys) C objects don't trip
# "built for newer iOS version" linker warnings.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.4}"
# rustup/cargo live in ~/.cargo; make them visible to non-login shells (Xcode).
# shellcheck disable=SC1090
source "$HOME/.cargo/env" 2>/dev/null || true

# PRIVACY: scrub the local build path out of the binary. Rust bakes absolute
# source paths (panic/`file!()`/error `Location`, mostly from ~/.cargo deps) into
# the staticlib as *string constants* — they survive stripping and get printed
# in the app's log console (e.g. "/Users/<you>/.cargo/.../sideloader.rs:85").
# `--remap-path-prefix` / `-ffile-prefix-map` rewrite $HOME -> /build at compile
# time so no username/identity ends up in the shipped app. (Changing these flags
# forces a full rebuild, which is intended — the old cache has the raw paths.)
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust-core"

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

cd "$ROOT"
echo "==> Repackaging SideInstallerFFI.xcframework"
rm -rf "$ROOT/SideInstallerFFI.xcframework"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libsideinstaller_ffi.a -headers rust-core/include \
  -library rust-core/target/aarch64-apple-ios-sim/release/libsideinstaller_ffi.a -headers rust-core/include \
  -output "$ROOT/SideInstallerFFI.xcframework"

echo "==> Done. (Re)generate the project with: xcodegen generate"
