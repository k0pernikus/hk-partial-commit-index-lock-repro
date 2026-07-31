# hk partial-commit `index.lock` reproduction

On a partial commit — some paths staged, others left modified — hk's `stash = "git"` step runs
`git stash push … -- <paths>` and aborts the whole run if the worktree `index.lock` is held.

[PR #1060](https://github.com/jdx/hk/pull/1060) (shipped in v1.51.0) fixed the common case: `run_git_stash`
now waits up to 775 ms for a lock that already exists, so a lock **released inside that window** recovers.
It is a pre-flight wait, not a retry — the stash command is still issued exactly once — so a lock that
**outlives the window** still aborts the run. That residual case is what this repository now reproduces,
against the latest hk.

Self-contained: `mise.toml` pins `jdx/hk@1.54.0`, and CI runs the reproduction on every push to `main`.

## Run

```bash
bash reproduce.sh
```

Override the pinned version to explore other releases:

```bash
HK_VERSION=1.50.0 bash reproduce.sh
```

It exits non-zero while the bug is present, so the CI run is red — hk stopping is the point. A green run
means a held lock no longer aborts the run, i.e. the retry landed.

## The three cases

| Case | `index.lock` | Expected on ≥ 1.51.0 | What it proves |
|:---|:---|:---|:---|
| `control` | never held | exit 0 | the pipeline is otherwise sound, so a failure below is the lock |
| `transient` | released after 300 ms | exit 0 | #1060's wait works — this is the case it fixed |
| `held` | held for the whole run | **exit 1 today** | the wait is not a retry; the residual bug |

Each case reports hk's exit status, how many stashes were left behind, and the unstaged file's content,
so a failure that stranded work is distinguishable from one that did not.

Observed across versions (git 2.47.3):

| hk | `control` | `transient` | `held` |
|:---|:---|:---|:---|
| 1.50.0 | exit 0 | exit 1 — no wait existed yet | exit 1 |
| 1.54.0 | exit 0 | exit 0 — #1060 works | exit 1 |

The `transient` row flipping at 1.51.0 is what makes `held` meaningful: the same harness confirms the
shipped fix and isolates what it did not cover.

## Reading the result

`reproduce.sh` drives hk's stash step through `hk run pre-commit`, not `git commit`: with a held
`.git/index.lock` a plain `git commit` fails on git's own index lock before hk runs, which would confound
the report. On 1.54.0 the held case prints hk's own failure at `src/git.rs:84`, which is the `cmd.run()?`
inside the `run_git_stash` helper #1060 added.

In every failing case the harness reports `stashes-left=0` and the unstaged file unchanged: under a held
lock `git stash push` fails atomically, creating no stash and leaving the worktree alone. A bounded retry
around the command therefore cannot duplicate a stash.

## Files

- `reproduce.sh` — the reproduction; exits red while the bug is present.
- `diag.sh` — why `hk run pre-commit` is used, not `git commit`: a plain `git commit` with a held lock
  fails on git's own index lock before hk runs, so it cannot isolate the hk bug.
- `hk.pkl` — minimal pre-commit config: `stash = "git"` plus one no-op step.
- `mise.toml` — pins `aqua:jdx/hk@1.54.0`.
