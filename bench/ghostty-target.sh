#!/usr/bin/env bash
# One job of ghostty's `build-libghostty-vt` matrix, for the fleet test:
#   ghostty-target.sh <zig target>
# Upstream runs `nix develop -c zig build -Demit-lib-vt -Dtarget=<target>`; Zig comes
# from mise at the version build.zig.zon requires, as in ghostty.sh.
source "$(dirname "$0")/lib.sh"
export BENCH_META_KEY="bench-results-${BUILDKITE_JOB_ID:-local}"

GHOSTTY_SHA="${GHOSTTY_SHA:-9ad3c422222e45b32c5f9ab9f4cd32e0e3694ef7}"
ZIG_VERSION="${ZIG_VERSION:-0.17.1}"
target="$1"
export ZIG_GLOBAL_CACHE_DIR="$BENCH_CACHE_DIR/zig/global-cache"
export ZIG_LOCAL_CACHE_DIR="$BENCH_CACHE_DIR/zig/local-cache"
export MISE_DATA_DIR="$BENCH_CACHE_DIR/mise"
export MISE_YES=1

machine_info
install_zig() {
  command -v mise >/dev/null || curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh
  export PATH="$HOME/.local/bin:$PATH"
  mise install "zig@$ZIG_VERSION"
}
run_section "zig toolchain" install_zig
export PATH="$HOME/.local/bin:$PATH"
ZIG="$(mise where "zig@$ZIG_VERSION")/zig"

run_section "checkout" clone_at https://github.com/ghostty-org/ghostty.git "$GHOSTTY_SHA" src
cd src
run_section "zig fetch" "$ZIG" build --fetch
run_section "build lib-vt $target" "$ZIG" build -Demit-lib-vt -Dtarget="$target"

cd "$BENCH_ROOT"
finish
