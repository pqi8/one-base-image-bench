# one-base-image-bench

Builds three projects on Linux arm64 with the same scripts on three platforms:
bk-compute (Mac VM runner), Buildkite hosted agents and GitHub Actions (`ubuntu-24.04-arm`).

| Project | Upstream commit | What runs |
|---|---|---|
| buildkite/agent | `23e06924dac1b683bc8653b731cd633af67d4a8a` | `go test ./...` and the linux/arm64 binary, in the repo's Docker Compose `agent` service |
| ghostty-org/ghostty | `9ad3c422222e45b32c5f9ab9f4cd32e0e3694ef7` | `zig build -Dapp-runtime=none` and `zig build test-lib-vt` |
| pingdotgg/t3code | `7ef0558f758882628d4aa5a68796ce7c374f90e1` | CI's "Build and Typecheck" job: install, desktop build, Electron launch, web boot, typecheck |

`bench/<project>.sh` does all the work. `.buildkite/*.yml` and `.github/workflows/*.yml` only choose the
runner and carry `.bench-cache` between runs. Each section prints `BENCH|<section>|<seconds>|<exit status>`.
