#!/usr/bin/env bash
set -euo pipefail

# TSUNAGI Whitepaper PDF Build Script
#
# Prerequisites:
#   - pandoc (https://pandoc.org/)
#   - A LaTeX distribution (texlive-latex-recommended, texlive-fonts-recommended)
#
# Install on Ubuntu/Debian:
#   sudo apt-get install pandoc texlive-latex-recommended texlive-fonts-recommended texlive-latex-extra
#
# Usage:
#   ./scripts/build-whitepaper.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INPUT="$PROJECT_ROOT/docs/whitepaper/tsunagi-whitepaper.md"
OUTPUT="$PROJECT_ROOT/docs/whitepaper/tsunagi-whitepaper-v1.pdf"

if ! command -v pandoc &> /dev/null; then
    echo "Error: pandoc is not installed."
    echo "Install with: sudo apt-get install pandoc texlive-latex-recommended texlive-fonts-recommended texlive-latex-extra"
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo "Error: whitepaper not found at $INPUT"
    exit 1
fi

echo "Building TSUNAGI whitepaper PDF..."
echo "  Input:  $INPUT"
echo "  Output: $OUTPUT"

pandoc "$INPUT" \
    -o "$OUTPUT" \
    --toc \
    --toc-depth=3 \
    --number-sections \
    --pdf-engine=pdflatex \
    --metadata title="TSUNAGI — Deterministic Cardano Node Architecture" \
    --metadata author="ASY" \
    --metadata date="2026" \
    --variable geometry:margin=1in \
    --variable fontsize=11pt \
    --variable documentclass=article \
    --variable linkcolor=blue \
    --variable urlcolor=blue \
    --variable toccolor=black \
    --highlight-style=tango

echo "Done: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"
