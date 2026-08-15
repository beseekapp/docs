# Platform40 Repository Sync Script Design

## Goal

Provide one workspace-level command that keeps every `platform40-*` repository in the `beseekapp` GitHub organization present and current under `/home/amri/repos/beseekapp`.

## Location and interface

The executable will be `/home/amri/repos/beseekapp/sync-platform40-repos.sh`.

```text
sync-platform40-repos.sh [--dry-run]
```

The script requires Bash, Git, and an authenticated GitHub CLI. It discovers repositories on every run through `gh repo list beseekapp`, filters names by the exact `platform40-` prefix, and includes active, archived, private, public, and forked repositories accessible to the authenticated account.

## Synchronization behavior

For a repository missing locally, the script clones it into a same-named directory using `gh repo clone`, which respects the user's configured Git protocol and authentication.

For an existing Git repository, the script always fetches and prunes `origin`. It fast-forwards the checked-out branch only when all of these conditions hold:

- the worktree and index are clean;
- HEAD is attached;
- the checked-out branch is the repository's GitHub default branch.

If any condition is false, the fetch remains useful but the script leaves local files and branches unchanged. Pulls use `--ff-only`, so the script never creates merge commits, rebases, resets, stashes, or discards work.

If the target path exists but is not a Git repository, the script reports a collision and does not overwrite it.

## Dry-run and reporting

`--dry-run` performs authentication and inventory checks, then prints the clone, fetch, update, or skip action it would take without changing repositories.

Each repository receives an explicit status. A final summary reports cloned, updated, fetched-only/skipped, unchanged, and failed counts. Any repository failure is isolated so remaining repositories continue; the final process exit status is nonzero if one or more failures occurred.

## Error handling

The script fails early when Bash, Git, or `gh` is missing, GitHub authentication is invalid, the organization query fails, or the destination is not writable. Repository-level network and Git failures are counted and reported without aborting the entire batch.

## Verification

Verification consists of:

- `bash -n` syntax validation;
- `shellcheck` when installed;
- a live `--dry-run` against the authenticated `beseekapp` inventory;
- assertions that the inventory includes archived repositories and only names beginning with `platform40-`;
- confirmation that the dry run identifies locally missing repositories without creating them.

The initial live inventory on 2026-08-15 contained 30 active matching repositories. Three were absent locally: `platform40-chatter`, `platform40-stowage`, and `platform40-harvester`. Archived matches, if present on later runs, are deliberately included.
