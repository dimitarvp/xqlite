#!/bin/bash
set -e

# =================CONFIGURATION=================
# Path to your NIF manifest (Relative to Project Root)
CARGO_MANIFEST="native/xqlitenif/Cargo.toml"
# The actual name of the package inside Cargo.toml
CRATE_NAME="xqlitenif"
# ===============================================

# 0. Safety & Context 🛡️
# Ensure Ctrl-C kills the whole script
trap "echo '❌ Script interrupted by user'; exit 1" SIGINT SIGTERM

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "📂 Context: Moving to Project Root ($PROJECT_ROOT)"
pushd "$PROJECT_ROOT" >/dev/null

# 1. Dependency Pre-flight Check 🛫
echo "🔍 Checking system dependencies..."
REQUIRED_TOOLS=("mix" "cargo" "jq" "git")
ALL_GOOD=true

for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    echo "❌ $tool is missing"
    ALL_GOOD=false
  else
    echo "✅ $tool"
  fi
done

if ! cargo set-version --version &>/dev/null; then
  echo "❌ cargo-edit (set-version) is missing. Install via: cargo install cargo-edit"
  ALL_GOOD=false
else
  echo "✅ cargo-edit"
fi

if [ "$ALL_GOOD" = false ]; then
  echo "💥 Missing dependencies. Aborting."
  popd >/dev/null
  exit 1
fi

# 2. Git Cleanliness Check 🧹
# mix_version requires a clean state. We check this early to avoid interactive prompts/failures.
if [ "$(git status --porcelain)" != "" ]; then
  echo "❌ Error: Git working directory is dirty."
  echo "   mix_version requires a clean state."
  echo "   Please commit your changes (including this script!) before releasing."
  popd >/dev/null
  exit 1
fi
echo "✨ Git is clean."
echo ""

# 3. Input Validation 🛡️
TYPE=$1
if [[ ! "$TYPE" =~ ^(patch|minor|major)$ ]]; then
  echo "❌ Error: Argument must be 'patch', 'minor', or 'major'."
  echo "Usage: ./scripts/release.sh <type>"
  popd >/dev/null
  exit 1
fi

# 4. Define Helper Functions 🛠️

# Get Rust version via metadata (Source of Truth for Rust)
get_rust_version() {
  cargo metadata --format-version 1 --no-deps --manifest-path "$CARGO_MANIFEST" |
    jq -r --arg name "$CRATE_NAME" '.packages[] | select(.name == $name) | .version'
}

# Get Elixir version via Mix config (Source of Truth for Elixir)
get_elixir_version() {
  mix run --no-start --no-compile -e 'IO.puts Mix.Project.config[:version]'
}

# 5. Capture Initial State 📸
echo "🚀 Starting release process for bump type: $TYPE"

OLD_RUST_VER=$(get_rust_version)
if [[ -z "$OLD_RUST_VER" || "$OLD_RUST_VER" == "null" ]]; then
  echo "❌ FATAL: Could not detect version for crate '$CRATE_NAME'."
  popd >/dev/null
  exit 1
fi

OLD_MIX_VER=$(get_elixir_version)
PRE_BUMP_COMMIT=$(git rev-parse HEAD)

echo "📦 Current Elixir version: $OLD_MIX_VER"
echo "📦 Current Rust version:   $OLD_RUST_VER"

# 6. Run mix version (The Driver) 💧
echo "Running mix version..."
# We use --$TYPE (e.g., --patch) as per mix_version args
mix version --"$TYPE"

# 7. Safety Valve: Verify Elixir Bump & Commit 🛑
# We must ensure mix_version actually did its job before we touch anything else.

NEW_MIX_VER=$(get_elixir_version)
POST_BUMP_COMMIT=$(git rev-parse HEAD)

# Check 1: Did the version string change?
if [ "$OLD_MIX_VER" == "$NEW_MIX_VER" ]; then
  echo "❌ FATAL: Elixir version did not change!"
  echo "   Was: $OLD_MIX_VER"
  echo "   Now: $NEW_MIX_VER"
  echo "   mix_version might have failed silently."
  popd >/dev/null
  exit 1
fi

# Check 2: Did a new commit appear?
if [ "$PRE_BUMP_COMMIT" == "$POST_BUMP_COMMIT" ]; then
  echo "❌ FATAL: mix version did not create a new commit!"
  echo "   We cannot proceed with amending. Aborting to protect history."
  popd >/dev/null
  exit 1
fi

echo "✅ mix.exs bumped to:  $NEW_MIX_VER"
echo "✅ New commit created: $POST_BUMP_COMMIT"

# 8. Update Rust Version (The Modern Way) 🦀
echo "🦀 Bumping Rust crate..."
cargo set-version --manifest-path "$CARGO_MANIFEST" "$NEW_MIX_VER"

# 9. Paranoid Verification of Rust Bump 🕵️‍♂️
CHECK_VER=$(get_rust_version)

if [[ "$CHECK_VER" != "$NEW_MIX_VER" ]]; then
  echo "❌ FATAL: Cargo.toml update failed!"
  echo "   Tried to upgrade from $OLD_RUST_VER to $NEW_MIX_VER"
  echo "   But cargo metadata reports: $CHECK_VER"
  echo "   Aborting before git operations."
  # Note: You are left with a dirty state here (Cargo.toml changed),
  # but your git history is safe (we haven't amended yet).
  popd >/dev/null
  exit 1
fi
echo "✅ Verified: Rust crate is now $CHECK_VER"

# 10. Git Magic (Amend & Retag) 🪄
echo "🎨 Amending git commit..."

# Stage the Rust changes
git add "$CARGO_MANIFEST"
# Try adding lockfile if it exists (cargo set-version usually updates it)
LOCK_FILE="${CARGO_MANIFEST%Cargo.toml}Cargo.lock"
if [ -f "$LOCK_FILE" ]; then
  git add "$LOCK_FILE"
fi

# Amend the commit created by mix_version
git commit --amend --no-edit >/dev/null

# Force move the tag to the new amended commit hash
TAG_NAME="v$NEW_MIX_VER"
git tag -f "$TAG_NAME" >/dev/null

echo "✅ Git commit amended and tag $TAG_NAME updated."
echo ""
echo "🎉 Release $NEW_MIX_VER successfully prepared!"
echo "Next steps:"
echo "  1. git push && git push --tags"
echo "  2. mix hex.publish"

# 11. Cleanup
popd >/dev/null
