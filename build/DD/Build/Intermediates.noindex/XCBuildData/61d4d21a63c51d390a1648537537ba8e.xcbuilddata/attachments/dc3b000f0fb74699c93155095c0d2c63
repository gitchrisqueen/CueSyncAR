#!/bin/sh
#!/bin/sh
#
# embed-build-identity.sh / CueSync AR
#
# Stamps the built product's Info.plist with the git revision it came from,
# so the app, the debug mirror and the os.Logger output can all answer
# "which build is on this phone?" (see Packages/CueSyncUI/BuildIdentity.swift).
#
# Wired in as the CueSyncAR target's "Embed Build Identity" post-build script
# by project.yml, so `xcodegen generate` reproduces it.
#
# RULE: this script must never fail a build. There is deliberately no
# `set -e`, every git invocation is guarded, and every exit path is 0. A
# checkout with no git history (CI's shallow/detached clone, a source
# tarball) yields "unknown" values, which BuildIdentity renders honestly.
#
# PRIVACY: only the short SHA, branch name, dirty flag and a UTC timestamp
# are written. Never emit SRCROOT, $HOME, the hostname or the build user —
# these values end up in a public binary, on the mirror page and in logs.

COMMIT="unknown"
BRANCH="unknown"
DIRTY="NO"
# UTC by design: a local timezone would leak roughly where the build ran.
BUILD_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || BUILD_DATE="unknown"

repo_root="${SRCROOT:-$PWD}"

if command -v git >/dev/null 2>&1 &&
   git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    sha=$(git -C "$repo_root" rev-parse --short=7 HEAD 2>/dev/null)
    [ -n "$sha" ] && COMMIT="$sha"

    # Detached HEAD (how CI checks out a PR) reports the literal "HEAD";
    # BuildIdentity renders that as "detached".
    ref=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ -n "$ref" ] && BRANCH="$ref"

    if [ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]; then
        DIRTY="YES"
    fi
fi

echo "note: build identity ${COMMIT} (${BRANCH}) dirty=${DIRTY} at ${BUILD_DATE}"

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -z "${TARGET_BUILD_DIR}" ] || [ -z "${INFOPLIST_PATH}" ] || [ ! -f "$plist" ]; then
    echo "warning: build identity not embedded — no Info.plist at the expected path"
    exit 0
fi

plist_buddy=/usr/libexec/PlistBuddy
if [ ! -x "$plist_buddy" ]; then
    echo "warning: build identity not embedded — PlistBuddy unavailable"
    exit 0
fi

set_key() {
    "$plist_buddy" -c "Set :$1 $2" "$plist" >/dev/null 2>&1 ||
        "$plist_buddy" -c "Add :$1 string $2" "$plist" >/dev/null 2>&1 ||
        echo "warning: could not write $1 to the built Info.plist"
}

set_key CueSyncGitCommit "$COMMIT"
set_key CueSyncGitBranch "$BRANCH"
set_key CueSyncGitDirty "$DIRTY"
set_key CueSyncBuildDate "$BUILD_DATE"

exit 0

