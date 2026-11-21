#!/usr/bin/env bash
# ghostty-org/ghostty: libghostty for Linux, as ghostty's test.yml runs it in the
# `build-linux-libghostty` job (zig build -Dapp-runtime=none) and the `test-lib-vt` job
# (zig build test-lib-vt). Upstream gets Zig from its Nix dev shell; here Zig comes from
# mise at the version build.zig.zon requires, the same way on every platform.
source "$(dirname "$0")/lib.sh"

GHOSTTY_SHA="${GHOSTTY_SHA:-9ad3c422222e45b32c5f9ab9f4cd32e0e3694ef7}"
ZIG_VERSION="${ZIG_VERSION:-0.17.1}"
# Upstream CI caches both Zig caches (ZIG_*_CACHE_DIR under /zig); so does this.
export ZIG_GLOBAL_CACHE_DIR="$BENCH_CACHE_DIR/zig/global-cache"
export ZIG_LOCAL_CACHE_DIR="$BENCH_CACHE_DIR/zig/local-cache"
export MISE_DATA_DIR="$BENCH_CACHE_DIR/mise"
export MISE_YES=1

machine_info
[ "${BENCH_CACHE_TRANSPORT:-}" = artifact ] && [ "${BENCH_CACHE:-cold}" = warm ] && run_section "cache restore" artifact_cache_restore

install_mise() {
  command -v mise >/dev/null && return 0
  curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh
}
install_zig() {
  install_mise
  export PATH="$HOME/.local/bin:$PATH"
  mise install "zig@$ZIG_VERSION"
  "$(mise where "zig@$ZIG_VERSION")/zig" version
}

run_section "zig toolchain" install_zig
export PATH="$HOME/.local/bin:$PATH"
ZIG="$(mise where "zig@$ZIG_VERSION")/zig"

run_section "checkout" clone_at https://github.com/ghostty-org/ghostty.git "$GHOSTTY_SHA" src
cd src

run_section "zig fetch" "$ZIG" build --fetch
run_section "build libghostty" "$ZIG" build -Dapp-runtime=none
run_section "test lib-vt" "$ZIG" build test-lib-vt

cd "$BENCH_ROOT"
[ "${BENCH_CACHE_TRANSPORT:-}" = artifact ] && [ "${BENCH_SAVE_CACHE:-}" = 1 ] && run_section "cache save" artifact_cache_save
finish
