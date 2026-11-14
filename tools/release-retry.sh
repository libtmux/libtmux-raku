#!/usr/bin/env bash
set -euo pipefail

mode=$1
test "$mode" = archive || test "$mode" = upload || exit 64
if test "$GITHUB_RUN_ATTEMPT" -eq 1; then
  if test "$mode" = upload; then
    printf 'needed=true\n' >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if test "$mode" = archive; then
  artifacts=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?per_page=100")
  count=$(jq '[.[].artifacts[] | select(.name == "release-candidate" and .expired == false)] | length' <<< "$artifacts")
  if test "$count" = 1; then
    gh run download "$GITHUB_RUN_ID" --repo "$GITHUB_REPOSITORY" \
      --name release-candidate --dir "$2"
    printf 'restored=true\n' >> "$GITHUB_OUTPUT"
    exit 0
  fi
  if test "$count" != 0; then
    echo 'More than one retained release archive exists; inspect the run before recovery.' >&2
    exit 1
  fi
fi

jobs=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?filter=all&per_page=100")
uploads=$(jq '[.[].jobs[].steps[]? | select(.name == "Upload the tested archive" and .conclusion != null and .conclusion != "skipped")]' <<< "$jobs")
if test "$mode" = archive; then
  if test "$(jq length <<< "$uploads")" != 0; then
    echo 'The original archive is unavailable after an upload attempt. Recover the original files; do not rebuild this release.' >&2
    exit 1
  fi
  exit 0
fi

if jq --exit-status 'any(.[]; .conclusion == "success")' <<< "$uploads" > /dev/null; then
  echo 'An earlier attempt completed this upload; continuing with registry verification.'
  printf 'needed=false\n' >> "$GITHUB_OUTPUT"
elif test "$(jq length <<< "$uploads")" != 0; then
  echo 'A previous upload was interrupted. Check Fez state and use verify mode if accepted; do not upload again blindly.' >&2
  exit 1
else
  printf 'needed=true\n' >> "$GITHUB_OUTPUT"
fi
