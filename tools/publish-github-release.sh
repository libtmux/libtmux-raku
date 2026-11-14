#!/usr/bin/env bash
set -euo pipefail

directory=$(realpath "$1")
tag=$2
repository=$3
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
version=${tag#v}
files=("LibTmux-$version.tar.gz" SHA256SUMS)
for file in "${files[@]}"; do
  test -f "$directory/$file"
done

release=$(gh api --paginate --slurp "repos/$repository/releases" | jq --compact-output --exit-status \
  --arg tag "$tag" '[.[][] | select(.tag_name == $tag)]
    | if length > 1 then error("Duplicate release tag") else .[0] // {} end')

# Check every existing asset before changing even an incomplete release.
for file in "${files[@]}"; do
  digest=$(sha256sum "$directory/$file")
  expected="sha256:${digest%% *}"
  existing=$(jq --raw-output --arg name "$file" \
    '[.assets[]? | select(.name == $name)]
      | if length > 1 then error("Duplicate release asset")
        elif length == 1 then .[0].digest // "unknown" else "" end' <<< "$release")
  if test -n "$existing" && test "$existing" != "$expected"; then
    printf 'Refusing to replace release asset: %s\n' "$file" >&2
    exit 1
  fi
done

if test "$release" = '{}'; then
  gh release create "$tag" --repo "$repository" --verify-tag --draft \
    --title "$tag" --generate-notes
  release='{"draft":true,"assets":[]}'
fi

for file in "${files[@]}"; do
  if ! jq --exit-status --arg name "$file" \
    'any(.assets[]?; .name == $name)' <<< "$release" > /dev/null; then
    gh release upload "$tag" "$directory/$file" --repo "$repository"
  fi
done

if jq --exit-status '.draft == true' <<< "$release" > /dev/null; then
  gh release edit "$tag" --repo "$repository" --draft=false
fi
