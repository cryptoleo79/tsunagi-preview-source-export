#!/bin/bash

set -e

if [ -z "$1" ]; then
  echo "Usage: ./scripts/release.sh v0.x.x"
  exit 1
fi

VERSION=$1

echo "🚀 Creating release $VERSION"

# Ensure clean working tree
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ Working tree not clean"
  exit 1
fi

# Create annotated tag
git tag -a "$VERSION" -m "TSUNAGI $VERSION"

# Push
git push origin "$VERSION"

echo "✅ Release $VERSION created and pushed"
