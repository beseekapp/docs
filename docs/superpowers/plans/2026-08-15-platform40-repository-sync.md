# Platform40 Repository Sync Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a safe repeatable command that discovers every accessible `beseekapp/platform40-*` GitHub repository, including archived repositories, clones missing repositories, and fast-forwards safe existing clones under `/home/amri/repos/beseekapp`.

**Architecture:** Keep the implementation as one dependency-light Bash program tracked in the `beseekapp/docs` repository, with a workspace-root symlink for convenient execution. Query inventory dynamically through authenticated GitHub CLI, isolate each repository operation, and allow updates only when the local repository is clean, attached, on its GitHub default branch, and connected to the expected origin.

**Tech Stack:** Bash 5+, Git, GitHub CLI (`gh`), a self-contained Bash integration-test harness, optional ShellCheck.

## Global Constraints

- Match repository names using the exact `platform40-` prefix in the `beseekapp` organization.
- Include active, archived, private, public, and forked matching repositories accessible to the authenticated account.
- Never reset, rebase, merge, stash, delete, or overwrite local work.
- Existing repositories always fetch and prune `origin`; only clean default-branch worktrees may run `git pull --ff-only`.
- Dirty, detached, non-default-branch, origin-mismatched, and non-Git collision paths must remain unchanged.
- `--dry-run` may authenticate, query GitHub, and inspect local state, but must not clone, fetch, pull, or create repository directories.
- The installed entry point is `/home/amri/repos/beseekapp/sync-platform40-repos.sh`.

---

### Task 1: Build the safe synchronization engine with integration tests

**Files:**
- Create: `/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh`
- Create: `/home/amri/repos/beseekapp/docs/tests/sync-platform40-repos-test.sh`

**Interfaces:**
- Consumes: `gh auth status`, `gh repo list`, `gh repo clone`, and ordinary `git -C` commands.
- Produces: `sync-platform40-repos.sh [--dry-run]`; environment override `PLATFORM40_ROOT`; exit `0` when all repositories succeed and nonzero when validation or any repository operation fails.

- [ ] **Step 1: Write the failing integration test harness**

Create `tests/sync-platform40-repos-test.sh` as an executable Bash test. It must create a temporary workspace and fake `gh` and `git` commands ahead of the real `PATH`. The fake GitHub inventory must contain these rows:

```text
platform40-present-clean	beseekapp/platform40-present-clean	main	false
platform40-present-dirty	beseekapp/platform40-present-dirty	main	false
platform40-archived-missing	beseekapp/platform40-archived-missing	main	true
```

The harness must run these assertions:

```bash
run_sync --dry-run
assert_contains "$output" "WOULD CLONE  platform40-archived-missing"
assert_not_logged "repo clone"
assert_not_logged "fetch --prune"

run_sync
assert_dir "$test_root/platform40-archived-missing/.git"
assert_logged "repo clone beseekapp/platform40-archived-missing"
assert_logged "fetch --prune origin"
assert_logged "pull --ff-only origin main"
assert_contains "$output" "SKIP UPDATE  platform40-present-dirty (dirty worktree; fetched only)"

mkdir -p "$test_root/platform40-collision"
inventory_add "platform40-collision\tbeseekapp/platform40-collision\tmain\tfalse"
run_sync_expect_failure
assert_contains "$output" "FAIL         platform40-collision (path exists and is not a Git repository)"
```

The fake `gh` must log every invocation, return success for `auth status`, emit the fixture inventory for `repo list`, and create `<destination>/.git` for `repo clone`. The fake `git` must log every invocation; recognize `.dirty`, `.branch`, `.origin`, and `.head` fixture files; return the expected origin; simulate fetch; and change `.head` from `before` to `after` only when `pull --ff-only` is invoked.

- [ ] **Step 2: Run the test to verify it fails before implementation**

Run:

```bash
bash tests/sync-platform40-repos-test.sh
```

Expected: nonzero exit because `scripts/sync-platform40-repos.sh` does not exist.

- [ ] **Step 3: Implement argument parsing, inventory, and safety gates**

Create `scripts/sync-platform40-repos.sh` with this structure:

```bash
#!/usr/bin/env bash
set -uo pipefail

readonly ORG="beseekapp"
readonly PREFIX="platform40-"
readonly ROOT="${PLATFORM40_ROOT:-/home/amri/repos/beseekapp}"
dry_run=false
cloned=0
updated=0
unchanged=0
fetched_only=0
skipped=0
failed=0

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

normalize_github_slug() {
  local value="${1%.git}"
  value="${value#git@github.com:}"
  value="${value#ssh://git@github.com/}"
  value="${value#https://github.com/}"
  value="${value#http://github.com/}"
  printf '%s\n' "${value,,}"
}

status_line() {
  printf '%-12s %s\n' "$1" "$2"
}

fail_repo() {
  status_line "FAIL" "$1 ($2)"
  ((failed += 1))
}

sync_repo() {
  local name="$1" full_name="$2" default_branch="$3" archived="$4"
  local destination="$ROOT/$name" suffix=""
  local origin actual_slug dirty branch before after
  [[ "$archived" == "true" ]] && suffix=" [archived]"

  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    if "$dry_run"; then
      status_line "WOULD CLONE" "$name$suffix"
      ((skipped += 1))
    elif gh repo clone "$full_name" "$destination"; then
      status_line "CLONED" "$name$suffix"
      ((cloned += 1))
    else
      fail_repo "$name" "clone failed"
    fi
    return
  fi

  if ! git -C "$destination" rev-parse --git-dir >/dev/null 2>&1; then
    fail_repo "$name" "path exists and is not a Git repository"
    return
  fi

  if ! origin="$(git -C "$destination" remote get-url origin 2>/dev/null)"; then
    fail_repo "$name" "origin remote is missing"
    return
  fi
  actual_slug="$(normalize_github_slug "$origin")"
  if [[ "$actual_slug" != "${full_name,,}" ]]; then
    fail_repo "$name" "origin points to $actual_slug, expected ${full_name,,}"
    return
  fi

  if ! dirty="$(git -C "$destination" status --porcelain)"; then
    fail_repo "$name" "could not inspect worktree"
    return
  fi
  branch="$(git -C "$destination" symbolic-ref --short -q HEAD 2>/dev/null || true)"

  if "$dry_run"; then
    status_line "WOULD FETCH" "$name$suffix"
    if [[ -n "$dirty" ]]; then
      status_line "SKIP UPDATE" "$name (dirty worktree; fetched only)"
    elif [[ -z "$branch" ]]; then
      status_line "SKIP UPDATE" "$name (detached HEAD; fetched only)"
    elif [[ -z "$default_branch" ]]; then
      status_line "SKIP UPDATE" "$name (no default branch; fetched only)"
    elif [[ "$branch" != "$default_branch" ]]; then
      status_line "SKIP UPDATE" "$name (on $branch, default is $default_branch; fetched only)"
    fi
    ((skipped += 1))
    return
  fi

  if ! git -C "$destination" fetch --prune origin; then
    fail_repo "$name" "fetch failed"
    return
  fi

  if [[ -n "$dirty" ]]; then
    status_line "FETCHED ONLY" "$name (dirty worktree)"
    ((fetched_only += 1))
    return
  fi
  if [[ -z "$branch" ]]; then
    status_line "FETCHED ONLY" "$name (detached HEAD)"
    ((fetched_only += 1))
    return
  fi
  if [[ -z "$default_branch" ]]; then
    status_line "FETCHED ONLY" "$name (no default branch)"
    ((fetched_only += 1))
    return
  fi
  if [[ "$branch" != "$default_branch" ]]; then
    status_line "FETCHED ONLY" "$name (on $branch, default is $default_branch)"
    ((fetched_only += 1))
    return
  fi

  before="$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)"
  if ! git -C "$destination" pull --ff-only origin "$default_branch"; then
    fail_repo "$name" "fast-forward pull failed"
    return
  fi
  after="$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$before" && "$before" != "$after" ]]; then
    status_line "UPDATED" "$name"
    ((updated += 1))
  else
    status_line "UNCHANGED" "$name"
    ((unchanged += 1))
  fi
}

sync_inventory() {
  local inventory="$1"
  local name full_name default_branch archived
  while IFS=$'\t' read -r name full_name default_branch archived; do
    [[ -n "$name" ]] || continue
    sync_repo "$name" "$full_name" "$default_branch" "$archived"
  done <<< "$inventory"

  printf '\nSummary: cloned=%d updated=%d unchanged=%d fetched-only=%d dry-run/skipped=%d failed=%d\n' \
    "$cloned" "$updated" "$unchanged" "$fetched_only" "$skipped" "$failed"
  ((failed == 0))
}

main() {
  if (($# > 1)); then usage >&2; return 2; fi
  if (($# == 1)); then
    [[ "$1" == "--dry-run" ]] || { usage >&2; return 2; }
    dry_run=true
  fi

  command -v gh >/dev/null || die "gh is required"
  command -v git >/dev/null || die "git is required"
  [[ -d "$ROOT" ]] || die "workspace does not exist: $ROOT"
  [[ -w "$ROOT" ]] || die "workspace is not writable: $ROOT"
  gh auth status -h github.com >/dev/null 2>&1 || die "GitHub CLI authentication is invalid"

  local inventory
  inventory="$(gh repo list "$ORG" --limit 1000 \
    --json name,nameWithOwner,isArchived,defaultBranchRef \
    --jq '.[] | select(.name | startswith("platform40-")) | [.name, .nameWithOwner, (.defaultBranchRef.name // ""), (.isArchived|tostring)] | @tsv')" \
    || die "could not query GitHub organization $ORG"
  [[ -n "$inventory" ]] || die "no $PREFIX repositories found in $ORG"

  sync_inventory "$inventory"
}

main "$@"
```

The inventory's archived field is reported but never filtered. The origin comparison prevents a same-named checkout from a different owner from being updated. The working-tree checks happen before fetch and remain valid because fetch changes remote-tracking references without changing the index or working tree.

Use these stable status labels so output is testable:

```text
CLONED       repository-name
UPDATED      repository-name
UNCHANGED    repository-name
FETCHED ONLY repository-name (reason)
WOULD CLONE  repository-name
WOULD FETCH  repository-name
SKIP UPDATE  repository-name (reason; fetched only)
FAIL         repository-name (reason)
```

Keep counters in the main shell rather than a pipeline subshell. Continue after repository-level failures and return `1` after printing the summary when `failed > 0`.

- [ ] **Step 4: Run the integration test to verify behavior passes**

Run:

```bash
chmod +x scripts/sync-platform40-repos.sh tests/sync-platform40-repos-test.sh
bash tests/sync-platform40-repos-test.sh
```

Expected: exit `0` and a final `PASS: sync-platform40-repos` line.

- [ ] **Step 5: Run static validation**

Run:

```bash
bash -n scripts/sync-platform40-repos.sh
bash -n tests/sync-platform40-repos-test.sh
if command -v shellcheck >/dev/null; then
  shellcheck scripts/sync-platform40-repos.sh tests/sync-platform40-repos-test.sh
fi
```

Expected: every executed command exits `0` with no diagnostics.

- [ ] **Step 6: Commit the tested engine**

Run:

```bash
git add scripts/sync-platform40-repos.sh tests/sync-platform40-repos-test.sh
git commit -m "feat: add safe platform40 repository sync"
```

Expected: one commit containing only the script and its test harness.

---

### Task 2: Install the workspace entry point and verify the live inventory

**Files:**
- Create symlink: `/home/amri/repos/beseekapp/sync-platform40-repos.sh` -> `docs/scripts/sync-platform40-repos.sh`
- Verify: `/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh`

**Interfaces:**
- Consumes: the tested script from Task 1 and the authenticated `amri` GitHub CLI session.
- Produces: the user-facing workspace command and a verified, non-mutating live inventory report.

- [ ] **Step 1: Add the workspace-root symlink safely**

First verify the target is absent or already points to the intended script:

```bash
test ! -e /home/amri/repos/beseekapp/sync-platform40-repos.sh || \
  test "$(readlink -f /home/amri/repos/beseekapp/sync-platform40-repos.sh)" = "/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh"
```

Then create or refresh the relative symlink:

```bash
ln -sfn docs/scripts/sync-platform40-repos.sh /home/amri/repos/beseekapp/sync-platform40-repos.sh
```

Expected: `readlink -f` resolves to the tracked script. Never replace a conflicting regular file or unrelated symlink.

- [ ] **Step 2: Record the set of locally missing repositories**

Run:

```bash
find /home/amri/repos/beseekapp -mindepth 1 -maxdepth 1 -type d -name 'platform40-*' -printf '%f\n' | sort
```

Expected before any real synchronization: `platform40-chatter`, `platform40-stowage`, and `platform40-harvester` are absent from the local names observed during design.

- [ ] **Step 3: Run the live dry-run through the installed entry point**

Run:

```bash
/home/amri/repos/beseekapp/sync-platform40-repos.sh --dry-run
```

Expected: exit `0`; every inventory name begins with `platform40-`; the three initially missing repositories are shown as `WOULD CLONE`; existing repositories show non-mutating `WOULD FETCH`/`SKIP UPDATE` decisions; no `git fetch`, `git pull`, or clone is executed.

- [ ] **Step 4: Prove the dry run created no repository directories**

Repeat the local-directory inventory from Step 2 and compare it byte-for-byte with the pre-run list.

Expected: identical lists.

- [ ] **Step 5: Verify repository and workspace state**

Run:

```bash
git -C /home/amri/repos/beseekapp/docs status --short --branch
readlink -f /home/amri/repos/beseekapp/sync-platform40-repos.sh
```

Expected: the docs repository is clean and the symlink resolves to `/home/amri/repos/beseekapp/docs/scripts/sync-platform40-repos.sh`.

The first mutating synchronization is intentionally a separate user action:

```bash
/home/amri/repos/beseekapp/sync-platform40-repos.sh
```

This clones missing repositories and safely fetches or fast-forwards existing repositories according to the approved rules.
