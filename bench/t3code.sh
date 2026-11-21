#!/usr/bin/env bash
# pingdotgg/t3code: the "Build and Typecheck" job from .github/workflows/ci.yml on Linux.
# It installs Vite+ and the workspace, builds the desktop app and server, launches the
# built Electron app under Xvfb, boots the built web client in headless Chromium, and
# typechecks. Upstream runs the apt install and the typecheck in the background; here
# they run in order so each section has its own time.
source "$(dirname "$0")/lib.sh"

T3CODE_SHA="${T3CODE_SHA:-7ef0558f758882628d4aa5a68796ce7c374f90e1}"
VP_VERSION="${VP_VERSION:-1.4.0}"   # pnpm-workspace.yaml catalog: vite-plus
NODE_VERSION="${NODE_VERSION:-26.13.1}"   # package.json engines.node
export VP_HOME="$BENCH_CACHE_DIR/vite-plus"
export npm_config_store_dir="$BENCH_CACHE_DIR/pnpm-store"
export pnpm_config_store_dir="$BENCH_CACHE_DIR/pnpm-store"
export ELECTRON_CACHE="$BENCH_CACHE_DIR/electron"
export PLAYWRIGHT_BROWSERS_PATH="$BENCH_CACHE_DIR/ms-playwright"
export CI=true
ARTIFACTS="$BENCH_ROOT/artifacts"
mkdir -p "$ARTIFACTS"

machine_info
[ "${BENCH_CACHE_TRANSPORT:-}" = artifact ] && [ "${BENCH_CACHE:-cold}" = warm ] && run_section "cache restore" artifact_cache_restore

apt_deps() {
  $SUDO apt-get update -qq -o Acquire::Languages=none
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends libsecret-1-dev pkg-config xvfb xauth
}
setup_vp() {
  if [ ! -x "$VP_HOME/bin/vp" ]; then
    curl -fsSL https://vite.plus -o "$BENCH_ROOT/vp-install.sh"
    VP_VERSION="$VP_VERSION" VP_NODE_MANAGER=yes bash "$BENCH_ROOT/vp-install.sh" </dev/null
  fi
  "$VP_HOME/bin/vp" env use "$NODE_VERSION"
  "$VP_HOME/bin/vp" --version
}

run_section "checkout" clone_at https://github.com/pingdotgg/t3code.git "$T3CODE_SHA" src \
  '/*' '!/.repos/' '!/apps/mobile/modules/t3-terminal/Vendor/**/*.a'
run_section "apt packages" apt_deps
cd src
run_section "vite+ and node" setup_vp
export PATH="$VP_HOME/bin:$PATH"
echo "pnpm store: $(vp pm store path 2>/dev/null || true)  cache dir: $(vp pm cache dir 2>/dev/null || true)"

run_section "vp install" vp install
run_section "ensure electron" vp run --filter @t3tools/desktop ensure:electron
run_section "build desktop" vp run build:desktop
run_section "verify preload" node apps/desktop/scripts/verify-preload-bundle.mjs

desktop_launch() {
  local electron
  electron=$(node -p "require('./apps/desktop/node_modules/electron')")
  ls -lL "$electron"; command -v xvfb-run
  timeout 240 xvfb-run -a node scripts/smoke-desktop-app.ts --executable "$electron" --app apps/desktop \
    --artifacts-dir "$ARTIFACTS/desktop-launch-check"
}
run_section "desktop launch" desktop_launch

# Only when the launch fails: start Electron directly and record why. Not part of the timing.
launch_diagnostics() {
  local electron
  electron=$(node -p "require('./apps/desktop/node_modules/electron')")
  echo "id: $(id)"; echo "page size: $(getconf PAGESIZE)"
  sysctl kernel.unprivileged_userns_clone kernel.apparmor_restrict_unprivileged_userns user.max_user_namespaces 2>&1 || true
  ls -l "$(dirname "$electron")/chrome-sandbox" || true
  echo "missing libraries:"; ldd "$electron" | grep 'not found' || echo none
  echo "--- electron --version"; timeout 30 "$electron" --version 2>&1 || echo "exit $?"
  echo "--- electron under xvfb, 20 s"
  timeout 20 xvfb-run -a "$electron" --enable-logging=stderr --v=0 apps/desktop 2>&1 | tail -60 || true
  echo "--- same with --no-sandbox"
  timeout 20 xvfb-run -a "$electron" --no-sandbox --enable-logging=stderr apps/desktop 2>&1 | tail -60 || true
  $SUDO dmesg 2>/dev/null | tail -20 || true
}
case "$BENCH_FAILED" in *"desktop launch"*)
  run_section "desktop launch diagnostics" launch_diagnostics
  [ -n "${BUILDKITE_JOB_ID:-}" ] && tail -c 60000 "$BENCH_ROOT/section-logs/desktop-launch-diagnostics.log" | buildkite-agent meta-data set bench-diagnostics || true
  ;; esac

chromium() {
  local browser
  if ! find "$PLAYWRIGHT_BROWSERS_PATH" -name chrome-headless-shell -type f 2>/dev/null | grep -q .; then
    node apps/web/node_modules/playwright/cli.js install --only-shell chromium
  fi
  browser=$(find "$PLAYWRIGHT_BROWSERS_PATH" -name chrome-headless-shell -type f -print -quit)
  test -n "$browser"
  if ldd "$browser" | grep '=> not found'; then
    $SUDO env PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" "$(command -v node)" apps/web/node_modules/playwright/cli.js install-deps chromium
  fi
}
run_section "chromium" chromium
run_section "web boot" timeout 180 node apps/web/scripts/verify-built-boot.ts
run_section "typecheck" timeout 600 node_modules/.bin/vpr typecheck

cd "$BENCH_ROOT"
[ "${BENCH_CACHE_TRANSPORT:-}" = artifact ] && [ "${BENCH_SAVE_CACHE:-}" = 1 ] && run_section "cache save" artifact_cache_save
finish
