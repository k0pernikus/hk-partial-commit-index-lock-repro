# hk partial-commit `index.lock` bug — reproduction

`hk`'s pre-commit stash (`stash = "git"`) aborts the run with **no retry** when it cannot acquire the
worktree `index.lock` while stashing a *partial* (path-subset) change. Deterministic and
self-contained.

## Run

```bash
bash reproduce.sh
```

The script **fails on purpose (exit 1)** when the bug reproduces, so the CI run goes **red** — hk
stopping is the point. Expected tail:

```text
BUG REPRODUCED: hk stopped 3/3 on a held index.lock with no retry, yet the identical pipeline
succeeds with no lock (exit 0) — so a bounded retry over the transient lock would recover.
```

A green run would mean hk did *not* stop (retry added / behaviour changed).

Attempt 1 prints hk's own failure, pointing at the source:

```text
stash – Running git stash (1 file)
git error: Unable to create '.../.git/index.lock': File exists.
git error: could not write index
Error: exited with code 1
git stash push --keep-index -m hk --include-untracked -- other.txt
Location:
    src/git.rs:853:17
```

## Files

- `reproduce.sh` — the repro. Isolates hk via `hk run pre-commit`: with a held `.git/index.lock` hk
  aborts 3/3; with no lock the same pipeline succeeds — so the lock is the sole blocker and hk gives
  up instead of retrying.
- `diag.sh` — shows *why* `hk run pre-commit` is used rather than `git commit`: a plain `git commit`
  with a pre-held lock fails on **git's own** index lock *before* hk runs, so it cannot isolate the
  hk bug.
- `mise.toml` — pins `aqua:jdx/hk@1.50.0` for reproducibility.
- `hk.pkl` — minimal pre-commit config: `stash = "git"` plus one no-op step.

## What it demonstrates

hk shells out `git stash push --keep-index -m hk --include-untracked -- <paths>` once, with no
retry / backoff / lock-wait (`src/git.rs:853`). git itself never waits for the index lock, so any
transient or stale `index.lock` aborts the whole hook. In a real `git commit` the contending lock is
*transient* — held during hk's stash inside the hook, gone before git's own index write — so a
bounded retry in hk would let the commit succeed. `stash = "patch-file"` does not help (dead alias to
the git path in v1.50.0); `stash = "none"` avoids the lock only by dropping unstaged stashing.
