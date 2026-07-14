# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
nix build .#claude              # Build the runner script
nix run .#claude -- --help      # Show CLI usage
nix flake check                 # Validate flake structure
```

End-to-end test (needs a terminal and a prior in-jail login - run `nix run .#claude` once and complete the login flow, which persists credentials in `~/.config/llm-jail/claude/default`):
```bash
nix run .#claude -- --dangerous -- -p "Write hello to /workspace/hello.txt" --max-turns 3
```

After changes to guest NixOS config, rebuilds are fast (only systemd units regenerate). Changes to `flake.nix` inputs or `writeShellApplication` trigger full rebuilds.

## Architecture

This is a Nix flake that runs coding agents inside QEMU microVMs with hardware-level isolation. No disk images - the guest boots on tmpfs with the host's `/nix/store` shared read-only via 9p. An overlayfs covers `/nix/store` and `/nix/var` is bind-mounted from the same backing volume so build artifacts land on disk (not root tmpfs) when `--store-disk` is used.

**Data flow:** `flake.nix` iterates `tools.nix`, builds a NixOS guest system per tool, wraps each with `lib/mkRunner.nix` into a QEMU launcher script.

**Host side (`lib/mkRunner.nix`):** A `writeShellApplication` that parses CLI args at runtime, writes env vars and tool args to a temp dir, sets up 9p virtfs mounts, optionally creates a store disk image, and launches QEMU with direct kernel boot. On NixOS hosts, `/run/current-system/sw` and `/etc/profiles/per-user/$USER` are auto-mounted so host packages are available in the guest.

**Guest side (`guests/common.nix` + `guests/claude.nix`):** Minimal NixOS. Three systemd services: `llmjail-mounts` parses kernel cmdline (`llmjail.mounts=tag:path:mode,...`) to mount user directories via 9p; `llmjail-winsize` reads `cols rows` lines from a dedicated virtio-serial port (`/dev/virtio-ports/llmjail.winsize`) and applies them via `stty` on `/dev/ttyS0` so the TUI receives SIGWINCH on host terminal resize; then `llmjail-tool` runs the actual tool on `/dev/ttyS0`. `ExecStopPost` powers off the VM when the tool exits. The host runner forwards SIGWINCH into the winsize port via a FIFO→unix-socket→`virtserialport` bridge (`socat`), so no QEMU patches are required.

ACP mode (`tools.nix` entries with `acp = true`, guest option `llmjail.acp`)
replaces the TTY entirely: the tool's stdio is fd-dup'd onto
`/dev/virtio-ports/llmjail.acp` (single RDWR open — two separate opens of a
virtio port are unreliable), stderr goes to the journal, the winsize service
is not defined, and the host runner (`--acp-sock PATH`) binds the port to a
Unix socket chardev instead of bridging SIGWINCH. Serial consoles go to log
files in RUNDIR, so the runner is safe to spawn from a daemon.

**Adding a new tool:** Add an entry to `tools.nix` pointing to a new guest module under `guests/`. The guest module imports `common.nix` and overrides `systemd.services.llmjail-tool.serviceConfig.ExecStart`.

## Key Constraints

- **virtio-serial drops host→guest writes until the guest opens the port.** ACP clients must retry `initialize`; don't "fix" this with sleeps in the runner.
- **The ACP socket path is a Unix socket, capped at ~108 bytes** by the kernel and QEMU's chardev. The default lives under `$TMPDIR`; a deeply nested `$TMPDIR` (or `--acp-sock`) will fail with "UNIX socket path ... is too long".
- **The ACP socket is an unauthenticated control channel.** Whoever can connect controls the guest agent, which holds forwarded API keys and a read-write workspace mount. There is no auth on the JSON-RPC channel itself - the trust boundary is filesystem permissions on the socket path. The default (`RUNDIR/acp.sock`) is safe because `RUNDIR` is created `0700`; a custom `--acp-sock` must live in an equally private directory.
- **9p can't mount single files.** `.gitconfig` is copied into the envfs temp dir on the host and copied out to `$HOME` by the guest mounts service.
- **Tool args use null-separated files** (`tool-args`) to preserve argument boundaries through the host→guest boundary. Don't use env vars for args with spaces.
- **`/run` is remounted by systemd in stage 2**, so guest 9p mounts must not go under `/run`. The envfs mount is at `/llmjail-env`.
- **`writeShellApplication` runs shellcheck.** Avoid `compgen` and other builtins that shellcheck flags. Use `env | grep` patterns instead.
- **`/nix/store` uses an overlay; `/nix/var` is bind-mounted from the same backing.** By default both use a tmpfs at `/.nix-backing`. Use `--store-disk SIZE` to use a disk-backed ext4 image instead, giving space for large builds and intermediate artifacts in `/nix/var/nix/builds/`. Dev shell environments can alternatively be captured on the host via `nix print-dev-env` (opt-in with `--dev-env`) and sourced in the guest.
- **The 9p store mount and overlay backing live outside `/nix`.** The host store is mounted read-only at `/.nix-lower/store` (used as the overlay lower layer directly - overlayfs does not reliably cross submount boundaries, so the lower must be the mounted filesystem itself). The overlay backing (ext4 or tmpfs) is at `/.nix-backing`. Keep this in mind when debugging mount issues inside the guest.
- **Tool state is jail-private.** Every tool (including the debug shell) keeps its state in a host dir `~/.config/llm-jail/<tool>/<profile>` (never the host tool's own config), mounted read-write at `/home/user/<configDirName>`. The tool is relocated into it via its native env var (`configEnvVar` in `tools.nix`, e.g. `CLAUDE_CONFIG_DIR`; `ZDOTDIR` for the shell), which `mkRunner.nix` writes into the env file consumed by `llmjail-tool.service`. A tool whose state spans several dirs points the remaining dirs into the same mount via exports in its launcher wrapper. The `--state-dir` flag (env: `LLMJAIL_STATE_DIR`) overrides the default jail state root (`~/.config/llm-jail`); `<tool>/<profile>` is appended beneath it. The deprecated `--config-dir`/`LLMJAIL_CONFIG_DIR` names are rejected/aliased. Never mount a directory the host tool also uses read-write - a jailed agent could plant hooks/settings the host tool would execute.
