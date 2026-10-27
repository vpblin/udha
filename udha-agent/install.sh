#!/usr/bin/env bash
# Build udha-agent on this Linux box and install it as a user service.
#
#   ./install.sh            build (in the official Swift container) + install + (re)start
#   ./install.sh --no-build install the existing .build/release binary
#
# Uses Docker's swift image because Ubuntu 26.04 has no native toolchain from
# swift.org yet; the binary links the Swift runtime statically so it runs on the
# host with nothing but libcurl/libxml2.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
IMAGE="${SWIFT_IMAGE:-swift:6.2-noble}"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "▶ building udha-agent in $IMAGE…"
  docker run --rm -v "$REPO":/repo -w /repo/udha-agent "$IMAGE" \
    swift build -c release --static-swift-stdlib 2>&1 | tail -3
fi

BIN=.build/release/udha-agent
[[ -x "$BIN" ]] || { echo "✗ $BIN missing"; exit 1; }
"$BIN" version >/dev/null || { echo "✗ binary does not run on this host"; exit 1; }

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m 755 "$BIN" "$HOME/.local/bin/udha-agent"
install -m 644 systemd/udha-agent.service "$HOME/.config/systemd/user/udha-agent.service"
systemctl --user daemon-reload
systemctl --user enable udha-agent.service >/dev/null
# Keep the user manager alive without a console login, so the agent runs headless.
loginctl enable-linger "$USER" 2>/dev/null || true

if "$HOME/.local/bin/udha-agent" status | grep -q "signed in: yes"; then
  systemctl --user restart udha-agent.service
  echo "✓ udha-agent installed and running:  systemctl --user status udha-agent"
else
  echo "✓ udha-agent installed. Sign in once, then start it:"
  echo "    udha-agent login       (open the printed URL through: ssh -L 8789:localhost:8789 $(hostname))"
  echo "    systemctl --user start udha-agent"
fi
