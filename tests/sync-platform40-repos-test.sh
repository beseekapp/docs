#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sync_script="$script_dir/../scripts/sync-platform40-repos.sh"
test_root="$(mktemp -d)"
fake_bin="$test_root/bin"
log_file="$test_root/commands.log"
inventory_file="$test_root/inventory.tsv"
mkdir -p "$fake_bin" "$test_root/workspace"
: > "$log_file"
cat > "$inventory_file" <<'INVENTORY'
platform40-present-clean	beseekapp/platform40-present-clean	main	false
platform40-present-dirty	beseekapp/platform40-present-dirty	main	false
platform40-archived-missing	beseekapp/platform40-archived-missing	main	true
INVENTORY

cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

cat > "$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
printf 'gh %s\n' "$*" >> "${FAKE_LOG:?}"
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "repo" && "${2:-}" == "list" ]]; then
  cat "${FAKE_INVENTORY:?}"
  exit 0
fi
if [[ "${1:-}" == "repo" && "${2:-}" == "clone" ]]; then
  destination="${4:?}"
  mkdir -p "$destination/.git"
  printf '%s\n' "${3:?}" > "$destination/.origin"
  printf 'main\n' > "$destination/.branch"
  printf 'before\n' > "$destination/.head"
  exit 0
fi
exit 1
GH
chmod +x "$fake_bin/gh"

cat > "$fake_bin/git" <<'GIT'
#!/usr/bin/env bash
set -uo pipefail
printf 'git %s\n' "$*" >> "${FAKE_LOG:?}"
if [[ "${1:-}" != "-C" ]]; then exit 1; fi
repo="${2:?}"
shift 2
case "${1:-}" in
  rev-parse)
    if [[ "${2:-}" == "--git-dir" ]]; then [[ -d "$repo/.git" ]]; exit $?; fi
    if [[ "${2:-}" == "HEAD" ]]; then cat "$repo/.head"; exit $?; fi
    ;;
  remote)
    [[ "${2:-}" == "get-url" && "${3:-}" == "origin" ]] || exit 1
    cat "$repo/.origin"
    ;;
  status)
    [[ "${2:-}" == "--porcelain" ]] || exit 1
    if [[ -f "$repo/.dirty" ]]; then printf ' M tracked-file\n'; fi
    ;;
  symbolic-ref)
    if [[ "${2:-}" == "--short" && "${3:-}" == "-q" && -f "$repo/.branch" ]]; then cat "$repo/.branch"; exit 0; fi
    exit 1
    ;;
  fetch)
    [[ "${2:-}" == "--prune" && "${3:-}" == "origin" ]]
    [[ ! -f "$repo/.fetch-fails" ]]
    ;;
  pull)
    [[ "${2:-}" == "--ff-only" && "${3:-}" == "origin" ]] || exit 1
    printf 'after\n' > "$repo/.head"
    ;;
  *) exit 1 ;;
esac
GIT
chmod +x "$fake_bin/git"

export FAKE_LOG="$log_file" FAKE_INVENTORY="$inventory_file"
export PATH="$fake_bin:$PATH"
export PLATFORM40_ROOT="$test_root/workspace"

for repo_name in platform40-present-clean platform40-present-dirty; do
  mkdir -p "$test_root/workspace/$repo_name/.git"
  printf 'beseekapp/%s\n' "$repo_name" > "$test_root/workspace/$repo_name/.origin"
  printf 'main\n' > "$test_root/workspace/$repo_name/.branch"
  printf 'before\n' > "$test_root/workspace/$repo_name/.head"
done
touch "$test_root/workspace/platform40-present-dirty/.dirty"

output=""
run_sync() {
  set +e
  output="$(bash "$sync_script" "$@" 2>&1)"
  run_status=$?
  set -e
}
run_sync_expect_failure() {
  run_sync "$@"
  [[ $run_status -ne 0 ]] || { printf 'expected sync to fail\n%s\n' "$output" >&2; exit 1; }
}
assert_status() { [[ "$run_status" -eq "$1" ]] || { printf 'expected status %s, got %s\n%s\n' "$1" "$run_status" "$output" >&2; exit 1; }; }
assert_contains() { [[ "$1" == *"$2"* ]] || { printf 'missing %s\n%s\n' "$2" "$1" >&2; exit 1; }; }
assert_not_logged() { ! grep -Fq -- "$1" "$log_file" || { printf 'unexpected log %s\n' "$1" >&2; exit 1; }; }
assert_logged() { grep -Fq -- "$1" "$log_file" || { printf 'missing log %s\n' "$1" >&2; exit 1; }; }
assert_dir() { [[ -d "$1" ]] || { printf 'missing directory %s\n' "$1" >&2; exit 1; }; }
inventory_add() { printf '%b\n' "$1" >> "$inventory_file"; }

set -e
run_sync --dry-run
assert_status 0
assert_contains "$output" "WOULD CLONE  platform40-archived-missing"
assert_not_logged "repo clone"
assert_not_logged "fetch --prune"

: > "$log_file"
run_sync
assert_status 0
assert_dir "$test_root/workspace/platform40-archived-missing/.git"
assert_logged "repo clone beseekapp/platform40-archived-missing"
assert_logged "fetch --prune origin"
assert_logged "pull --ff-only origin main"
assert_contains "$output" "FETCHED ONLY platform40-present-dirty (dirty worktree)"

# Real runs fetch but never mutate repositories that are detached, on another
# branch, or have no default branch.
for repo_name in platform40-detached platform40-nondefault platform40-no-default; do
  mkdir -p "$test_root/workspace/$repo_name/.git"
  printf 'beseekapp/%s\n' "$repo_name" > "$test_root/workspace/$repo_name/.origin"
  printf 'before\n' > "$test_root/workspace/$repo_name/.head"
done
printf 'main\n' > "$test_root/workspace/platform40-no-default/.branch"
printf 'dev\n' > "$test_root/workspace/platform40-nondefault/.branch"
inventory_add $'platform40-detached\tbeseekapp/platform40-detached\tmain\tfalse'
inventory_add $'platform40-nondefault\tbeseekapp/platform40-nondefault\tmain\tfalse'
inventory_add $'platform40-no-default\tbeseekapp/platform40-no-default\t\tfalse'
: > "$log_file"
run_sync
assert_status 0
assert_contains "$output" "FETCHED ONLY platform40-detached (detached HEAD)"
assert_contains "$output" "FETCHED ONLY platform40-nondefault (on dev, default is main)"
assert_contains "$output" "FETCHED ONLY platform40-no-default (no default branch)"
[[ "$(cat "$test_root/workspace/platform40-detached/.head")" == before ]] || exit 1
[[ "$(cat "$test_root/workspace/platform40-nondefault/.head")" == before ]] || exit 1
[[ "$(cat "$test_root/workspace/platform40-no-default/.head")" == before ]] || exit 1
assert_not_logged "$test_root/workspace/platform40-detached pull --ff-only origin main"
assert_not_logged "$test_root/workspace/platform40-nondefault pull --ff-only origin main"
assert_not_logged "$test_root/workspace/platform40-no-default pull --ff-only origin main"

mkdir -p "$test_root/workspace/platform40-collision"
inventory_add "platform40-collision\tbeseekapp/platform40-collision\tmain\tfalse"
mkdir -p "$test_root/workspace/platform40-origin-mismatch/.git"
printf 'someone-else/platform40-origin-mismatch\n' > "$test_root/workspace/platform40-origin-mismatch/.origin"
printf 'main\n' > "$test_root/workspace/platform40-origin-mismatch/.branch"
printf 'before\n' > "$test_root/workspace/platform40-origin-mismatch/.head"
inventory_add "platform40-origin-mismatch\tbeseekapp/platform40-origin-mismatch\tmain\tfalse"
mkdir -p "$test_root/workspace/platform40-fetch-failure/.git"
printf 'beseekapp/platform40-fetch-failure\n' > "$test_root/workspace/platform40-fetch-failure/.origin"
printf 'main\n' > "$test_root/workspace/platform40-fetch-failure/.branch"
printf 'before\n' > "$test_root/workspace/platform40-fetch-failure/.head"
touch "$test_root/workspace/platform40-fetch-failure/.fetch-fails"
inventory_add "platform40-fetch-failure\tbeseekapp/platform40-fetch-failure\tmain\tfalse"
run_sync_expect_failure
assert_contains "$output" "FAIL         platform40-collision (path exists and is not a Git repository)"
assert_contains "$output" "FAIL         platform40-origin-mismatch (origin points to someone-else/platform40-origin-mismatch, expected beseekapp/platform40-origin-mismatch)"
assert_contains "$output" "FAIL         platform40-fetch-failure (fetch failed)"
assert_contains "$output" "Summary: cloned=0 updated=0 unchanged=2 fetched-only=4 dry-run/skipped=0 failed=3"

printf 'PASS: sync-platform40-repos\n'
