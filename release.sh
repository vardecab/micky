#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

usage() {
    echo "Usage: $0 current|patch|minor|major" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
ACTION="$1"
case "$ACTION" in
    current|patch|minor|major) ;;
    *) usage ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Releases must be built on macOS." >&2
    exit 1
fi
command -v gh >/dev/null 2>&1 || { echo "Install GitHub CLI (gh) first." >&2; exit 1; }
gh auth status >/dev/null

BRANCH="$(git branch --show-current)"
if [[ "$BRANCH" != "main" ]]; then
    echo "Run this from the main branch." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or discard working tree changes before releasing." >&2
    exit 1
fi

git fetch origin main --tags
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo "Local main must match origin/main before releasing." >&2
    exit 1
fi

PLISTBUDDY="/usr/libexec/PlistBuddy"
[[ -x "$PLISTBUDDY" ]] || { echo "PlistBuddy was not found." >&2; exit 1; }
CURRENT_VERSION="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_NUMBER="$("$PLISTBUDDY" -c 'Print :CFBundleVersion' Info.plist)"
if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Info.plist version must use MAJOR.MINOR.PATCH; found $CURRENT_VERSION." >&2
    exit 1
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "CFBundleVersion must be an integer; found $BUILD_NUMBER." >&2
    exit 1
fi

case "$ACTION" in
    current) VERSION="$CURRENT_VERSION" ;;
    patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    major) VERSION="$((MAJOR + 1)).0.0" ;;
esac
TAG="v$VERSION"

if git show-ref --verify --quiet "refs/tags/$TAG" || [[ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]]; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists." >&2
    exit 1
fi

VERSION_FILES_CHANGED=false
VERSION_COMMITTED=false
restore_uncommitted_version() {
    if [[ "$VERSION_FILES_CHANGED" == true && "$VERSION_COMMITTED" == false ]]; then
        git reset --quiet -- Info.plist README.md
        git checkout -- Info.plist README.md
    fi
}
trap restore_uncommitted_version EXIT

if [[ "$ACTION" != "current" ]]; then
    git var GIT_AUTHOR_IDENT >/dev/null
    VERSION_FILES_CHANGED=true
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" Info.plist
    "$PLISTBUDDY" -c "Set :CFBundleVersion $((BUILD_NUMBER + 1))" Info.plist

    python3 - "$VERSION" README.md <<'PY'
import re
import sys

version, readme_path = sys.argv[1:]
with open(readme_path, encoding="utf-8") as source:
    readme = source.read()

badge = re.compile(
    r"!\[Version \d+\.\d+\.\d+\]"
    r"\(https://img\.shields\.io/badge/version-[^)]+\)"
)
readme, count = badge.subn(
    f"![Version {version}](https://img.shields.io/badge/version-{version}-blue)",
    readme,
    count=1,
)
if count != 1:
    raise SystemExit("Could not update the README version badge.")

heading = f"### {version}\n"
if heading not in readme:
    history_intro = "App versions follow Semantic Versioning (`MAJOR.MINOR.PATCH`). The macOS build number increments separately.\n\n"
    if history_intro not in readme:
        raise SystemExit("Could not find the README version history section.")
    entry = (
        f"### {version}\n\n"
        f"- [Release notes](https://github.com/vardecab/micky/releases/tag/v{version})\n\n"
    )
    readme = readme.replace(history_intro, history_intro + entry, 1)

with open(readme_path, "w", encoding="utf-8") as destination:
    destination.write(readme)
PY

fi

"$ROOT/build-and-run.sh" --package-only
ARCHIVE="$ROOT/build/Micky-$VERSION-macos.zip"
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$ROOT/build/Micky.app" "$ARCHIVE"

if [[ "$ACTION" != "current" ]]; then
    git add Info.plist README.md
    git commit -m "Release $TAG"
    VERSION_COMMITTED=true
    git push origin main
fi

gh release create "$TAG" "$ARCHIVE" \
    --title "Micky $VERSION" \
    --generate-notes \
    --target main

gh release view "$TAG" --json url --jq .url
