#!/usr/bin/env bash
# End-to-end ACP smoke test. Requirements: KVM, Nix, and credentials for
# the jailed ACP agent. Tool state is jail-private (separate from the
# host tool config), so provide credentials one of two ways: export the
# tool's API key (the runner forwards it into the VM's env file), or
# pre-seed the jail state dir ~/.config/llm-jail/<tool>/default before
# running. Not run in CI — this boots a real VM and spends real tokens.
#
# The ACP tool is selected with ACP_TOOL (default claude-acp):
#   ./tests/acp-e2e.sh                       # claude-acp, needs ANTHROPIC_API_KEY
#   ACP_TOOL=codex-acp ./tests/acp-e2e.sh    # codex-acp, needs OPENAI_API_KEY
#                                            # + a seeded provider config.toml
# Run from the repo root.
set -euo pipefail

ACP_TOOL="${ACP_TOOL:-claude-acp}"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKDIR=$(mktemp -d)
ACP_SOCK="$WORKDIR/acp.sock"
MARKER="hello-from-acp-$$"

# The ACP adapter stays alive after a prompt completes (it awaits more
# requests), so the VM does NOT power off on its own here — teardown is
# our job. setsid gives the runner its own process group so we can kill
# the whole tree (runner bash + foreground QEMU) in one signal.
cleanup() {
  if [ -n "${VM_PID:-}" ] && kill -0 "$VM_PID" 2>/dev/null; then
    kill -TERM -- "-$VM_PID" 2>/dev/null || true
    sleep 2
    kill -KILL -- "-$VM_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "workspace: $WORKDIR/ws"
mkdir -p "$WORKDIR/ws"

( cd "$WORKDIR/ws" && exec setsid nix run "$REPO_ROOT#$ACP_TOOL" -- \
    --acp-sock "$ACP_SOCK" ) </dev/null &>"$WORKDIR/vm.log" &
VM_PID=$!

echo "VM launched ($ACP_TOOL, pgid $VM_PID), driving ACP session..."
python3 "$REPO_ROOT/tests/acp-client.py" \
  --sock "$ACP_SOCK" \
  --prompt "Create a file named hello.txt in the current directory containing exactly the text: $MARKER" \
  --timeout 420 \
  --trace

echo "checking workspace result..."
if grep -q "$MARKER" "$WORKDIR/ws/hello.txt"; then
  echo "PASS: agent wrote hello.txt through the ACP channel"
else
  echo "FAIL: hello.txt missing or wrong content" >&2
  echo "--- vm.log tail ---" >&2
  tail -50 "$WORKDIR/vm.log" >&2
  exit 1
fi
# cleanup() tears down the VM process group on exit.
