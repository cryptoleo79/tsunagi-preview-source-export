#!/usr/bin/env bash
set -euo pipefail

# Install tsunagi systemd user units from docs/systemd/ into ~/.config/systemd/user/.
# Usage:
#   ./scripts/install_systemd_units.sh                         # install all units
#   ./scripts/install_systemd_units.sh tsunagi-preview.service  # install specific unit(s)
#   ./scripts/install_systemd_units.sh --enable tsunagi-preview.service tsunagi-sancho.service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$REPO_DIR/docs/systemd"
DEST_DIR="$HOME/.config/systemd/user"

ENABLE=false
UNITS=()

for arg in "$@"; do
    if [ "$arg" = "--enable" ]; then
        ENABLE=true
    else
        UNITS+=("$arg")
    fi
done

# Default: all units in docs/systemd/
if [ ${#UNITS[@]} -eq 0 ]; then
    for f in "$SRC_DIR"/*.service "$SRC_DIR"/*.timer; do
        [ -f "$f" ] && UNITS+=("$(basename "$f")")
    done
fi

if [ ${#UNITS[@]} -eq 0 ]; then
    echo "ERROR: no units found in $SRC_DIR"
    exit 1
fi

mkdir -p "$DEST_DIR"

echo "=== Installing systemd user units ==="
echo "Source:      $SRC_DIR"
echo "Destination: $DEST_DIR"
echo

for unit in "${UNITS[@]}"; do
    src="$SRC_DIR/$unit"
    if [ ! -f "$src" ]; then
        echo "WARN: $src not found, skipping"
        continue
    fi
    cp "$src" "$DEST_DIR/$unit"
    echo "  installed: $unit"
done

echo
echo "Reloading systemd user daemon..."
systemctl --user daemon-reload
echo "Done."

if [ "$ENABLE" = true ]; then
    echo
    echo "Enabling and starting units..."
    for unit in "${UNITS[@]}"; do
        if [[ "$unit" == *.timer ]] || [[ "$unit" == *.service ]]; then
            if [ -f "$DEST_DIR/$unit" ]; then
                systemctl --user enable --now "$unit" 2>&1 || true
                echo "  enabled: $unit"
            fi
        fi
    done
fi

echo
echo "=== Done ==="
echo
echo "Useful commands:"
echo "  systemctl --user status tsunagi-mainnet.service"
echo "  systemctl --user status tsunagi-preview.service"
echo "  systemctl --user status tsunagi-sancho.service"
echo "  systemctl --user list-timers"
