#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "usage: scripts/release.sh X.Y.Z"
  exit 2
}

[[ $# -eq 1 ]] || usage
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  print -u2 "release: version must look like X.Y.Z (got '$VERSION')"
  exit 2
}
TAG="v$VERSION"

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "release: working tree is not clean. Commit or stash first."
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  print -u2 "release: refusing to release from branch '$CURRENT_BRANCH' (expected main)"
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  print -u2 "release: tag $TAG already exists"
  exit 1
fi

print "release: running tests..."
make test

CURRENT_VERSION="$(grep -o 'say2Version = "[0-9.]*"' Sources/Say2Core/Models.swift | grep -o '[0-9.]*')"
if [[ -z "$CURRENT_VERSION" ]]; then
  print -u2 "release: could not read the current say2Version from Sources/Say2Core/Models.swift"
  exit 1
fi

if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
  print "release: say2Version is already $VERSION, no bump commit needed -- tagging the current commit"
else
  print "release: bumping version $CURRENT_VERSION -> $VERSION..."
  sed -i '' "s/public let say2Version = \"[0-9.]*\"/public let say2Version = \"$VERSION\"/" \
    Sources/Say2Core/Models.swift
  sed -i '' "s/tag: \"v[0-9.]*\"/tag: \"$TAG\"/" Formula/say2.rb

  if [[ -z "$(git status --porcelain -- Sources/Say2Core/Models.swift Formula/say2.rb)" ]]; then
    print -u2 "release: version bump produced no changes -- check the sed patterns still match"
    exit 1
  fi

  git add Sources/Say2Core/Models.swift Formula/say2.rb
  git commit -m "Release $TAG"
fi

git tag "$TAG"

print ""
print "release: done locally. Nothing has been pushed."
print "  Recommended before publishing: make smoke"
print "  When you're ready to make it public, run:"
print "    git push && git push origin $TAG"
