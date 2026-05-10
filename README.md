# Helix file watcher plugin

This is a helix plugin made using steel. To install, you can use the `forge` command line tool,
which also requires having a rust toolchain installed.

You can either clone the repo and then from the root run:

`forge install`

Or you can do:

`forge pkg install --git https://github.com/mattwparas/helix-file-watcher.git`.

This will build and install the library.

You should then be able to use the library like so:

```steel
(require "helix-file-watcher/file-watcher.scm")
```

To start the watcher with the default 2000 ms reload delay:

```scheme
(spawn-watcher)
```

To configure the reload delay, pass it in milliseconds:

```scheme
(spawn-watcher 1000)
```

## Manual system test

`scripts/test-zellij-cpu.sh` is a local system-level smoke test, not a default
CI test. It starts Helix inside zellij, edits a watched file, removes and
recreates it, samples Helix thread CPU usage from `/proc`, and checks the Helix
log for Steel/runtime failures.

Use it after changing watcher behavior or after deploying the plugin into your
local Helix environment:

```sh
scripts/test-zellij-cpu.sh
```

The script assumes a real Linux user session with `hx`, `zellij`, `script`,
`rg`, `ps`, `awk`, `nproc`, and `/proc` available. It is intentionally not wired
into normal CI because it depends on terminal behavior, process accounting, and
machine load; those make CPU thresholds and interactive startup flaky in
headless runners. Prefer Rust unit/integration tests for CI coverage, and keep
this script for manual or explicitly-triggered release/deployment checks.

Useful environment variables:

- `HELIX_FILE_WATCHER_TEST_DIR`: scratch directory, default
  `/tmp/hx-file-watcher-zellij`.
- `HELIX_FILE_WATCHER_MAX_CPU_PERCENT`: maximum accepted sampled Helix CPU
  percentage, default `50`.

## Development notes

Build the plugin with the same path you use for installation or packaging. For
example, local development can use `forge install`, while Nix-based packaging can
use:

```sh
nix build .#default --no-link
```

After changing watcher behavior, run the manual system test against a Helix
environment that loads the build you want to verify:

```sh
scripts/test-zellij-cpu.sh
```

Keep `file-watcher.scm` focused on Helix document lookup and reload decisions.
Keep `src/lib.rs` focused on filesystem watching, watched-path reconciliation,
event filtering, and batching. Avoid moving Helix editor state into Rust or
doing heavy event processing in Steel callbacks.

## Troubleshooting

Start Helix with a log file when diagnosing watcher behavior:

```sh
RUST_BACKTRACE=1 hx -vvv --log /tmp/hx-file-watcher.log path/to/file
```

Expected healthy log lines include:

- `watching open files`
- `starting event loop`
- `reloading file: ...` after an external write

Useful failure signals:

- `error[E08]`: an uncaught Steel error, commonly from IO performed inside a
  callback.
- `borrowed mutably`: FFI borrow/lifetime conflict between Steel and the native
  watcher object.
- `failed reading file metadata`: a watched file disappeared before reload
  comparison; this should be logged and skipped, not crash Helix.
- high sampled CPU in `scripts/test-zellij-cpu.sh`: look for a busy loop around
  event receive, debounce, or callback scheduling.

If changes appear not to load, check the store path in the Helix log and confirm
that your package manager or plugin installer is pointing at the intended build.
