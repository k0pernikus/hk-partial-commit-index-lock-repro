# hk pre-commit `index.lock` behaviour

**The user story.** A pre-commit hook grows. Every step is small and fast, and several of them touch the
git index — a generator that stages its output, a `git update-index --chmod=+x`, a codegen task that adds
what it wrote. Individually they are unremarkable. Run concurrently, they collide on `.git/index.lock`,
one step dies, and it takes every sibling step with it.

This repository pins the latest hk (`1.54.0`) and separates that defect from the lock behaviours that are
correct, so the two are not confused for each other.

**hk creates this contention itself.** Its step locking keys on the files a step *declares* — its glob,
its `stage` list. A `fix` command that writes the index is opaque to it, so hk schedules such steps in
parallel with nothing serialising them.

**It is not a timeout being too short.** The 775 ms budget [#1060](https://github.com/jdx/hk/pull/1060)
added applies only to the three shell `git stash push` sites. hk's index add (`add()`, `src/git.rs:1487`)
uses libgit2 with **no wait and no retry at all**, so a contended index there fails instantly.

## The five checks

Each is its own script and its own CI job, so each has its own log.

| Check | Scenario | Expected |
|:---|:---|:---|
| [`check_no_lock_succeeds.sh`](check_no_lock_succeeds.sh) | no lock held | green — the control |
| [`check_lock_released_inside_wait_window_recovers.sh`](check_lock_released_inside_wait_window_recovers.sh) | lock released after 300 ms | green — #1060 works |
| [`check_lock_outliving_wait_window_aborts.sh`](check_lock_outliving_wait_window_aborts.sh) | lock nothing ever releases | green — aborting is correct |
| [`check_concurrent_index_writers_collide.sh`](check_concurrent_index_writers_collide.sh) | 24 parallel steps run `git update-index` | **red — the defect** |
| [`check_script_spawned_git_collides.sh`](check_script_spawned_git_collides.sh) | 24 parallel steps run a script that stages its own output | **red — the defect, realistic form** |

## Why three checks are green

They exist to foreclose wrong diagnoses. `#1060` (shipped v1.51.0) added `run_git_stash`, which waits up
to 775 ms — 25/50/100/200/400 — for an *already-present* lock before issuing the stash.

The middle check shows that recovers a lock released inside the window; run it with `HK_VERSION=1.50.0`
and it fails, because no wait existed before 1.51.0. The third shows a lock nothing releases still aborts,
which is deliberate — #1060 says it means to *"preserve Git's normal failure when a lock persists"*. Both
behaviours are correct and pinned so they cannot regress unnoticed.

## Why two checks are red

24 steps with disjoint globs, so hk's file locks see no conflict and run them concurrently. Each step's
`fix` writes the index — directly via `git update-index` in one check, via a generator script that stages
its own output in the other. They collide:

```text
fatal: Unable to create '<repo>/.git/index.lock': File exists.
Another git process seems to be running in this repository, e.g. …
```

**The delays are random, not synchronised.** Each step calls
[`random_fast_sleep.sh`](random_fast_sleep.sh), which draws its own delay in 0.010–0.149 s. Giving every
step the same sleep would manufacture the collision; real steps finish at unrelated moments. The cost is
that any single pair overlapping is unlikely, so the scenario relies on step *count* instead. Measured
locally, 10 runs each:

| concurrent index writers | runs that collided |
|:---|:---|
| 6 | 1 |
| 12 | 2 |
| 24 | 9 |
| 48 | 10 |

At 24 the checks observe 5/5, and each needs only one collision across five attempts to report the defect.
Which step loses is a race and does not matter; that one loses is the claim.

Three things make it worse than a lost write:

- **No tolerance on this path** — libgit2, no wait, no retry, as above.
- **One collision aborts every sibling.** The surviving steps report `aborted`, so an unrelated formatter
  is cancelled by a race it took no part in.
- **A config author cannot declare the constraint.** There is no way to mark a step as needing exclusive
  index access. `depends` can serialise by hand, but only if you already know which opaque commands touch
  the index — and in the script form, hk could not know even in principle.

The second form is the one real configs hit.
[`regenerate_and_stage.sh`](regenerate_and_stage.sh) stands in for it.

## Run

```bash
bash check_no_lock_succeeds.sh
bash check_lock_released_inside_wait_window_recovers.sh
bash check_lock_outliving_wait_window_aborts.sh
bash check_concurrent_index_writers_collide.sh
bash check_script_spawned_git_collides.sh
```

Override the pinned version with `HK_VERSION=<x.y.z>`.

## Notes

The lock checks drive `hk run pre-commit`, not `git commit`: with a held `.git/index.lock` a plain
`git commit` fails on git's own lock before hk runs, which would confound the result.
[`why_not_git_commit.sh`](why_not_git_commit.sh) demonstrates that.

Every check reports `hk exit`, stashes left behind, and the unstaged file's content. Under a held lock
`git stash push` fails atomically — no stash created, worktree untouched — so a retry could not duplicate
a stash.

Git's wording differs by version, so the checks key on hk's exit status rather than on matching an error
string: git 2.54.0 reports `Unable to create '…/index.lock': File exists` followed by
`could not write index`, while git 2.47.3 reports only the latter.

## Files

- `check_*.sh` — the five checks above.
- `lib_hk_partial_commit.sh` — shared scenario setup and the lock / concurrency modes.
- `hk.pkl` — minimal config for the lock checks: `stash = "git"` plus one no-op step.
- `hk_concurrent_index_writers.pkl`, `hk_script_spawned_git.pkl` — the two grown, racing configs.
- `random_fast_sleep.sh` — per-step random delay, so the race is not manufactured.
- `regenerate_and_stage.sh` — stands in for a generator that stages its own output.
- `why_not_git_commit.sh` — why `hk run pre-commit` is used instead of `git commit`.
- `mise.toml` — pins `aqua:jdx/hk@1.54.0`.
