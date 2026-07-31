# hk partial-commit `index.lock` behaviour

On a partial commit — some paths staged, one path left modified but unstaged — hk's `stash = "git"` step
stashes the unstaged remainder through the shell `git stash push … -- <paths>`, and aborts the whole run
if the worktree `index.lock` is held while it does so.

[PR #1060](https://github.com/jdx/hk/pull/1060) (shipped in v1.51.0) fixed the common case: `run_git_stash`
now waits up to 775 ms for a lock that already exists, so a lock **released inside that window** recovers.
It is a pre-flight wait, not a retry — the stash command is still issued exactly once — so a lock that
**outlives the window** still aborts the run.

This repository pins the latest hk (`1.54.0`) and checks all three outcomes separately, so the fixed case
and the unfixed one are visible side by side rather than collapsed into one verdict.

## The three checks

Each is its own script and its own CI job, so each has its own log.

| Check | `index.lock` | Expected | What it establishes |
|:---|:---|:---|:---|
| [`check_no_lock_succeeds.sh`](check_no_lock_succeeds.sh) | never held | green | the control — the scenario, the pinned hk and the runner are sound, so any red below is the lock |
| [`check_lock_released_inside_wait_window_recovers.sh`](check_lock_released_inside_wait_window_recovers.sh) | released after 300 ms | green | #1060's wait works — this is precisely the case it fixed |
| [`check_lock_outliving_wait_window_aborts.sh`](check_lock_outliving_wait_window_aborts.sh) | held for the whole run | **red today** | the wait is not a retry — the residual bug |

The third check exits non-zero while the bug is present, so its job is red on purpose. It turns green when
the stash command is retried within a bounded budget rather than merely waited on beforehand.

## Run

```bash
bash check_no_lock_succeeds.sh
bash check_lock_released_inside_wait_window_recovers.sh
bash check_lock_outliving_wait_window_aborts.sh
```

Override the pinned version to explore other releases:

```bash
HK_VERSION=1.50.0 bash check_lock_released_inside_wait_window_recovers.sh
```

## Why the middle check matters

It is what makes the third check meaningful. The same harness, run across versions (git 2.47.3):

| hk | control | lock released inside the window | lock outliving the window |
|:---|:---|:---|:---|
| 1.50.0 | green | **red** — no wait existed yet | red |
| 1.54.0 | green | **green** — #1060 works | red |

The middle column flipping at 1.51.0 confirms the shipped fix landed, and isolates exactly what it did
not cover. Without it, a single red result could just as easily mean the fix never worked at all.

## Reading a failure

The checks drive `hk run pre-commit`, not `git commit`: with a held `.git/index.lock` a plain `git commit`
fails on git's own index lock before hk runs, which would confound the result.
[`why_not_git_commit.sh`](why_not_git_commit.sh) demonstrates that.

On 1.54.0 the held case prints hk's own failure at `src/git.rs:84:5`, which is the `cmd.run()?` inside the
`run_git_stash` helper #1060 added:

```text
  stash – Running git stash (1 file)
git error: could not write index
Error: exited with code 1
git stash push --keep-index -m hk --include-untracked -- other.txt

Location:
    src/git.rs:84:5
```

Every check reports `hk exit`, how many stashes were left behind, and the unstaged file's content. In each
failing case that is `stashes-left=0` with the file unchanged: under a held lock `git stash push` fails
atomically, creating no stash and leaving the worktree alone — so a bounded retry around the command cannot
duplicate a stash.

Git's wording for the contention differs by version, which is why the checks key on hk's exit status rather
than on matching an error string: git 2.54.0 reports `Unable to create '…/index.lock': File exists` followed
by `could not write index`, while git 2.47.3 reports only the latter.

## Files

- `check_*.sh` — the three checks above, one scenario each.
- `lib_hk_partial_commit.sh` — shared scenario setup: the temp repo, the partial state, and the lock modes.
- `why_not_git_commit.sh` — why `hk run pre-commit` is used instead of `git commit`.
- `hk.pkl` — minimal pre-commit config: `stash = "git"` plus one no-op step.
- `mise.toml` — pins `aqua:jdx/hk@1.54.0`.
