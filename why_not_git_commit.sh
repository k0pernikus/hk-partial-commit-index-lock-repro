#!/usr/bin/env bash
# Diagnostic: does a held .git/index.lock fail git commit on its OWN account (no hk), or is it
# specifically hk's stash that hits it? Isolates the two by (A) committing in a repo with NO hk
# installed, and (B) invoking hk's pre-commit pipeline directly (no git commit).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== A) plain 'git commit' with NO hk installed, held index.lock ==="
a="$(mktemp --directory)"
(
  cd "$a"
  git init --quiet --initial-branch=main
  git config user.email a@b.c
  git config user.name a
  printf 'v1\n' >f
  git add f
  git commit --quiet --message init
  printf 'v2\n' >f
  git add f
  : >.git/index.lock
  out="$(git commit --message x 2>&1)"
  echo "  rc=$?"
  printf '%s\n' "$out" | sed 's/^/  | /'
)
rm --recursive --force "$a"

echo
echo "=== B) 'hk run pre-commit' directly (no git commit), partial-staged, held index.lock ==="
b="$(mktemp --directory)"
(
  cd "$b"
  cp "$here/hk.pkl" "$here/mise.toml" .
  mise trust "$b/mise.toml" >/dev/null 2>&1 || true
  mise install >/dev/null 2>&1 || true
  if hkbin="$(mise which hk 2>/dev/null)"; then export PATH="$(dirname "$hkbin"):$PATH"; fi
  git init --quiet --initial-branch=main
  git config user.email a@b.c
  git config user.name a
  printf 'v1\n' >keep.txt
  printf 'v1\n' >other.txt
  git add keep.txt other.txt hk.pkl mise.toml
  git commit --quiet --message init
  hk install >/dev/null 2>&1
  printf 'v2\n' >keep.txt
  printf 'v2\n' >other.txt
  git add keep.txt
  : >.git/index.lock
  out="$(hk run pre-commit 2>&1)"
  echo "  rc=$?"
  printf '%s\n' "$out" | sed 's/^/  | /'
)
rm --recursive --force "$b"
