# shellcheck shell=bash
# Shared setup for the hk pre-commit checks in this repository.
#
# Every check builds a partial commit — some paths staged, one path left modified but unstaged — so
# hk stashes the unstaged remainder as a path subset through the shell `git stash push -- <paths>`.
#
# The lock checks drive `hk run pre-commit`, NOT `git commit`: with a held .git/index.lock a plain
# `git commit` fails on git's OWN lock before hk ever runs, which would confound the result.

# hk_scenario_setup <checkout-dir> [pkl-file]
# Builds a throwaway repo with the given hk config, installs the pinned hk, and leaves cwd inside it.
hk_scenario_setup() {
  local here="$1" pkl="${2:-hk.pkl}" repo hkbin
  repo="$(mktemp --directory)"
  # shellcheck disable=SC2064
  trap "rm --recursive --force '$repo'" EXIT
  cd "$repo" || return 1

  cp "$here/$pkl" ./hk.pkl
  cp "$here/mise.toml" .
  cp "$here/regenerate_and_stage.sh" "$here/random_fast_sleep.sh" .
  if [ -n "${HK_VERSION:-}" ]; then
    printf '[tools]\n"aqua:jdx/hk" = "%s"\n' "$HK_VERSION" >mise.toml
  fi
  mise trust "$repo/mise.toml" >/dev/null
  mise install >/dev/null
  hkbin="$(mise which hk)" || return 1
  PATH="$(dirname "$hkbin"):$PATH"
  export PATH

  echo "### $(hk --version 2>&1)  ($(type -p hk))"
  echo "### $(git --version)"
  echo

  git init --quiet --initial-branch=main
  git config user.email repro@example.com
  git config user.name repro
}

hk_scenario_commit_base() {
  git add --all
  git commit --quiet --message init
  hk install >/dev/null
}

# --- single-step lock scenario -------------------------------------------------------------------

hk_lock_scenario_files() {
  printf 'v1\n' >keep.txt
  printf 'v1\n' >other.txt
}

hk_lock_scenario_partial_state() {
  git stash clear
  printf 'v2\n' >keep.txt
  printf 'v2\n' >other.txt
  git add keep.txt
}

# hk_run_pre_commit_with_lock <none|transient|held>
# Sets HK_OUTPUT; returns hk's exit status.
hk_run_pre_commit_with_lock() {
  local mode="$1" releaser="" rc
  hk_lock_scenario_partial_state

  case "$mode" in
    transient)
      : >.git/index.lock
      (sleep 0.3 && rm --force .git/index.lock) &
      releaser=$!
      ;;
    held)
      : >.git/index.lock
      ;;
  esac

  HK_OUTPUT="$(hk run pre-commit 2>&1)"
  rc=$?

  if [ -n "$releaser" ]; then
    wait "$releaser"
  fi
  rm --force .git/index.lock

  echo "  hk exit=$rc  stashes-left=$(git stash list | wc --lines)  other.txt=$(tr --delete '\n' <other.txt)"
  return "$rc"
}

# --- concurrent index-writer scenario -----------------------------------------------------------
#
# Many steps with DISJOINT globs, so hk's file locks see no conflict and run them in parallel. Each
# step's fix shells out to git, an external process outside hk's own Repo mutex, so they contend for
# .git/index.lock with nothing serialising them. Delays are random per step, so the step COUNT is what
# makes a collision reliable; WHICH step loses is a race and does not matter.

HK_INDEX_WRITER_COUNT=48

hk_index_writer_scenario_files() {
  local i
  for ((i = 0; i < HK_INDEX_WRITER_COUNT; i++)); do
    printf 'v1\n' >"index_trigger$i.txt"
    printf '#!/usr/bin/env bash\n' >"script$i.sh"
  done
  printf 'v1\n' >leftover.txt
}

# hk_run_pre_commit_with_concurrent_index_writers <generation>
# Sets HK_OUTPUT; returns hk's exit status.
hk_run_pre_commit_with_concurrent_index_writers() {
  local generation="$1" i rc triggers=()
  # Each attempt must start from the committed state, or artifacts a previous attempt staged change
  # the scenario and a later run fails for an unrelated reason.
  git stash clear
  git reset --quiet
  rm --force generated*.txt
  git checkout --quiet -- .
  for ((i = 0; i < HK_INDEX_WRITER_COUNT; i++)); do
    printf 'v%s\n' "$generation" >"index_trigger$i.txt"
    triggers+=("index_trigger$i.txt")
  done
  git add "${triggers[@]}"
  printf 'unstaged %s\n' "$generation" >leftover.txt

  HK_OUTPUT="$(hk run pre-commit 2>&1)"
  rc=$?
  echo "  attempt $generation: hk exit=$rc  index.lock-collision=$(hk_saw_index_lock_collision && echo yes || echo no)"
  return "$rc"
}

# --- sentinel-shaped scenario ---------------------------------------------------------------------
#
# Mirrors a real in-use config rather than one built to collide: many file-only formatter steps, four
# generators that let hk stage their output, and exactly ONE step that shells out to git. See
# hk_sentinel_shaped.pkl for why each part is shaped that way.

HK_SENTINEL_TRIGGERS=(
  src.py
  conf.yml
  conf.toml
  conf.pklconf
  base.json
  gen_logo.trigger
  gen_targets.trigger
  gen_readme.trigger
  gen_completions.trigger
  vm_scripts/deploy.sh
)

hk_sentinel_scenario_files() {
  local name
  mkdir --parents vm_scripts
  for name in "${HK_SENTINEL_TRIGGERS[@]}"; do
    printf 'v1\n' >"$name"
  done
  printf 'v1\n' >leftover.txt
}

# hk_run_pre_commit_sentinel_shaped <generation>
# Sets HK_OUTPUT; returns hk's exit status.
hk_run_pre_commit_sentinel_shaped() {
  local generation="$1" name rc
  git stash clear
  git reset --quiet
  rm --force logo.out targets.out readme.out badge_python.out badge_mise.out completions.json
  git checkout --quiet -- .

  for name in "${HK_SENTINEL_TRIGGERS[@]}"; do
    printf 'v%s\n' "$generation" >"$name"
  done
  git add "${HK_SENTINEL_TRIGGERS[@]}"
  printf 'unstaged %s\n' "$generation" >leftover.txt

  HK_OUTPUT="$(hk run pre-commit 2>&1)"
  rc=$?
  echo "  attempt $generation: hk exit=$rc  index.lock-collision=$(hk_saw_index_lock_collision && echo yes || echo no)"
  return "$rc"
}

hk_saw_index_lock_collision() {
  printf '%s\n' "$HK_OUTPUT" | grep --quiet --fixed-strings "index.lock"
}

hk_print_output() {
  echo "  --- hk output ---"
  printf '%s\n' "$HK_OUTPUT" | sed 's/^/  | /'
  echo "  -----------------"
}
