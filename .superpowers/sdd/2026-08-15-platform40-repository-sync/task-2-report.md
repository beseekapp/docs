# Task 2 Report: workspace entry point and live inventory

## Result

The workspace-root symlink was created safely, but it is currently broken because
the target script is not present in the external docs checkout.

- Symlink: `/home/amri/repos/beseekapp/sync-platform40-repos.sh`
- Requested target: `/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh`
- `readlink -f`: unresolved (target missing)
- Commit: none (no tracked worktree changes were required)

## Verification

Commands and results:

```text
$ bash docs/tests/sync-platform40-repos-test.sh
PASS: sync-platform40-repos

$ bash -n docs/scripts/sync-platform40-repos.sh docs/tests/sync-platform40-repos-test.sh
(success, no output)

$ test ! -e /home/amri/repos/beseekapp/sync-platform40-repos.sh || \
    test "$(readlink -f /home/amri/repos/beseekapp/sync-platform40-repos.sh)" = \
    "/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh"
(success before installation; target was absent)

$ ln -sfn docs/scripts/sync-platform40-repos.sh \
    /home/amri/repos/beseekapp/sync-platform40-repos.sh
(success; relative symlink created)

$ find /home/amri/repos/beseekapp -mindepth 1 -maxdepth 1 -type d \
    -name 'platform40-*' -printf '%f\n' | sort
27 existing directories observed; no `platform40-chatter`,
`platform40-stowage`, or `platform40-harvester` directories.

$ /home/amri/repos/beseekapp/sync-platform40-repos.sh --dry-run
exit 127: `/usr/bin/bash: .../sync-platform40-repos.sh: No such file or directory`

$ find ... (repeated inventory)
byte-for-byte identical to the pre-run inventory (`yes`).

$ gh auth status -h github.com
authentication invalid: active `amri` account token is invalid.

$ git -C /home/amri/repos/beseekapp/docs status --short --branch
## main...origin/main [ahead 3]
```

## Concerns / blockers

1. `/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh` does not
   exist in the external docs checkout, so the installed entry point cannot run.
   The tested Task 1 files exist only in this isolated worktree at
   `docs/scripts/` and `docs/tests/`.
2. Even after the target script is installed in the external checkout, the live
   inventory dry-run requires re-authenticating GitHub CLI (`gh auth login -h
   github.com`) because the current `amri` token is invalid.
3. No clone, fetch, pull, or other repository synchronization was performed.

## Path Fix Verification

The Task 1 scripts were relocated to the docs-repository roots in this worktree:

- `scripts/sync-platform40-repos.sh`
- `tests/sync-platform40-repos-test.sh`

This places them at the final checkout paths expected by the workspace entry
point: `/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh` and
`/home/amri/repos/beseekapp/docs/tests/sync-platform40-repos-test.sh`.

Commands and results:

```text
$ bash tests/sync-platform40-repos-test.sh
PASS: sync-platform40-repos

$ bash -n scripts/sync-platform40-repos.sh tests/sync-platform40-repos-test.sh
(success, no output)

$ git diff --check
(success, no output)
```
