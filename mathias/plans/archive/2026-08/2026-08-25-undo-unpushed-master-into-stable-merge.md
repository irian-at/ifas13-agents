# Undo the unpushed master→stable merge

## Context

`master` was merged into `stable` (merge commit `70e8f9f1d`) before a colleague's
pending commit landed on `origin/master`. The merge has not been pushed, so it can be
discarded and redone later against the complete `master`.

State verified:
- `HEAD` = `70e8f9f1d` (the merge), first parent `5641f2962` = pre-merge `stable` tip
- `ORIG_HEAD` = `5641f2962` — same commit, so `ORIG_HEAD` is a safe target
- Working tree clean, no untracked/modified files
- `origin/stable` is 56 commits behind local `stable` — the merge was never pushed
- `stash@{0}` was created on `master`; unaffected by resetting `stable`

## Change

Single command, run on branch `stable`:

```bash
git reset --hard ORIG_HEAD    # == git reset --hard 5641f2962
```

## Verification

```bash
git log --oneline -3          # tip should be 5641f2962, no merge commit
git status                    # clean, "ahead of origin/stable by 55 commits"
git stash list                # stash@{0} still present
```

Recovery if needed: the merge stays reachable via `git reflog` (`70e8f9f1d`) — nothing
is lost.

## Afterwards

Once the colleague's commit is on `origin/master`:

```bash
git fetch origin
git merge origin/master
```

## Alternative (no action)

Keeping the merge is also fine — merging again after the colleague pushes just adds a
second merge commit to `stable`. Resetting only buys a cleaner single-merge history.
