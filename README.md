# hk partial-commit `index.lock` reproduction

Reproduces an `hk` pre-commit bug. On a partial commit — some paths staged, others left modified —
hk's `stash = "git"` step runs `git stash push … -- <paths>` once and aborts the whole run if the
worktree `index.lock` is briefly held, with no retry. The contention is transient, so a re-run
succeeds; hk gives up on a recoverable condition.

Self-contained: `mise.toml` pins `jdx/hk@1.50.0`, and CI runs the reproduction on every push to
`main`.

## Run

```bash
bash reproduce.sh
```

It exits non-zero when the bug reproduces, so the CI run is red — hk stopping is the point. A green
run means hk no longer stops (a retry was added or the behaviour changed).

## Reading the result

`reproduce.sh` drives hk's stash step through `hk run pre-commit`, not `git commit`: with a held
`.git/index.lock` hk aborts all three attempts; with no lock the same pipeline succeeds, so the lock
is the sole blocker and hk gives up instead of retrying. The first attempt prints hk's own failure at
`src/git.rs:853`.

## Files

- `reproduce.sh` — the reproduction; exits red on the bug.
- `diag.sh` — why `hk run pre-commit` is used, not `git commit`: a plain `git commit` with a held
  lock fails on git's own index lock before hk runs, so it cannot isolate the hk bug.
- `hk.pkl` — minimal pre-commit config: `stash = "git"` plus one no-op step.
- `mise.toml` — pins `aqua:jdx/hk@1.50.0`.
