#!/usr/bin/env bash
#
# commit.sh - thin git wrapper that builds a Conventional Commits v1.0.0
# message from flags and runs `git commit` with it via HEREDOC.
#
# Usage:
#   commit.sh --type <type> [--scope <scope>] [--breaking]
#             --subject <subject>
#             [--body <body>]
#             [--refs <issue>]   (repeatable; produces "Refs: <issue>" footers)
#             [--closes <issue>] (repeatable; produces "Closes: <issue>" footers)
#             [--breaking-desc <text>] (text for the BREAKING CHANGE: footer;
#                                       only used when --breaking is set)
#             [--coauthor "Name <email>"] (repeatable)
#             [--dry-run]
#
# Hard rules:
#   - Refuses --no-verify.
#   - Refuses if working tree has no staged changes (unless --allow-empty given).
#   - Subject is trimmed and capped at 72 characters; refuses if shorter than 1.
#   - Type is validated against an allow-list.
#
# Exit codes:
#   0 success
#   2 bad usage
#   3 nothing staged
#   4 git commit failed

set -euo pipefail

VALID_TYPES=(feat fix perf refactor style test docs build ci chore revert)

type=""
scope=""
breaking=0
breaking_desc=""
subject=""
body=""
refs=()
closes=()
coauthors=()
dry_run=0
allow_empty=0

die() {
  printf 'commit.sh: %s\n' "$1" >&2
  exit "${2:-2}"
}

is_valid_type() {
  local needle="$1"
  local t
  for t in "${VALID_TYPES[@]}"; do
    [[ "$t" == "$needle" ]] && return 0
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)          type="${2:-}"; shift 2 ;;
    --scope)         scope="${2:-}"; shift 2 ;;
    --breaking)      breaking=1; shift ;;
    --breaking-desc) breaking_desc="${2:-}"; shift 2 ;;
    --subject)       subject="${2:-}"; shift 2 ;;
    --body)          body="${2:-}"; shift 2 ;;
    --refs)          refs+=("${2:-}"); shift 2 ;;
    --closes)        closes+=("${2:-}"); shift 2 ;;
    --coauthor)      coauthors+=("${2:-}"); shift 2 ;;
    --dry-run)       dry_run=1; shift ;;
    --allow-empty)   allow_empty=1; shift ;;
    --no-verify)     die "refusing --no-verify; fix the hook or pass the change" 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

[[ -n "$type" ]]    || die "--type is required" 2
[[ -n "$subject" ]] || die "--subject is required" 2

is_valid_type "$type" || die "invalid --type '$type' (allowed: ${VALID_TYPES[*]})" 2

subject="${subject#"${subject%%[![:space:]]*}"}"
subject="${subject%"${subject##*[![:space:]]}"}"
[[ -n "$subject" ]] || die "--subject is empty after trimming" 2
if (( ${#subject} > 72 )); then
  die "subject is ${#subject} chars (max 72): $subject" 2
fi
case "$subject" in
  *.)
    die "subject must not end with a period" 2
    ;;
esac
# The subject is the header's single line; a newline would spill into the body
# and break the "first line is the header" contract.
case "$subject" in
  *$'\n'*)
    die "subject must be a single line (no newlines)" 2
    ;;
esac

if (( breaking )) && [[ -z "$breaking_desc" ]]; then
  breaking_desc="$subject"
fi

header="$type"
if [[ -n "$scope" ]]; then
  # Scope must be lowercase kebab-case only. Besides matching the convention,
  # this blocks characters like ')' or ':' that would corrupt the header, e.g.
  # a scope of "foo)bar" producing "feat(foo)bar): ...".
  if [[ ! "$scope" =~ ^[a-z0-9-]+$ ]]; then
    die "scope must be lowercase kebab-case (a-z, 0-9, -): $scope" 2
  fi
  header="${header}(${scope})"
fi
(( breaking )) && header="${header}!"
header="${header}: ${subject}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  die "not inside a git repository" 2
fi

if (( ! allow_empty )); then
  if git diff --cached --quiet; then
    die "nothing staged. stage changes first, or pass --allow-empty" 3
  fi
fi

msg="$header"
if [[ -n "$body" ]]; then
  msg="${msg}

${body}"
fi

footers=""
append_footer() {
  if [[ -z "$footers" ]]; then
    footers="$1"
  else
    footers="${footers}
$1"
  fi
}

if (( breaking )); then
  append_footer "BREAKING CHANGE: ${breaking_desc}"
fi
for r in "${refs[@]:-}";   do [[ -n "$r" ]] && append_footer "Refs: $r"; done
for c in "${closes[@]:-}"; do [[ -n "$c" ]] && append_footer "Closes: $c"; done
for a in "${coauthors[@]:-}"; do [[ -n "$a" ]] && append_footer "Co-authored-by: $a"; done

if [[ -n "$footers" ]]; then
  msg="${msg}

${footers}"
fi

if (( dry_run )); then
  printf '%s\n' "$msg"
  exit 0
fi

if ! git commit -m "$(cat <<COMMIT_MSG_EOF
${msg}
COMMIT_MSG_EOF
)"; then
  die "git commit failed" 4
fi

git --no-pager log -1 --format='%h %s'
