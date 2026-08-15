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
    status_line "SKIP UPDATE" "$name (dirty worktree; fetched only)"
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
  if ! inventory="$(gh repo list "$ORG" --limit 1000 \
    --json name,nameWithOwner,isArchived,defaultBranchRef \
    --jq '.[] | select(.name | startswith("platform40-")) | [.name, .nameWithOwner, (.defaultBranchRef.name // ""), (.isArchived|tostring)] | @tsv')"; then
    die "could not query GitHub organization $ORG"
  fi
  [[ -n "$inventory" ]] || die "no $PREFIX repositories found in $ORG"

  sync_inventory "$inventory"
}

main "$@"
