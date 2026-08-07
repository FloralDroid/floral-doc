#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILDER_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=../build_floral.sh
source "$BUILDER_DIR/build_floral.sh"

TEST_ROOT=$(mktemp -d /tmp/floral-build-script-test.XXXXXX)

cleanup_test() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup_test EXIT

AOSP_DIR="$TEST_ROOT/aosp"
PATCH_DIR="$TEST_ROOT/redroid-patches"
PATCH_HISTORY_DEPTH=32
ENVSETUP_ROOT="$TEST_ROOT/envsetup"
SOURCE_REPO="$AOSP_DIR/system/core"
PATCH_ROOT="$PATCH_DIR/android-test/system/core"
PATCH_FLOW="$AOSP_DIR/patch-flow"

mkdir -p "$AOSP_DIR/.repo/manifests" "$SOURCE_REPO" "$PATCH_ROOT"
git -C "$SOURCE_REPO" init --quiet
git -C "$SOURCE_REPO" config user.name "Floral Build Test"
git -C "$SOURCE_REPO" config user.email "build-test@floraldroid.invalid"
printf '<manifest><default revision="refs/tags/android-test"/></manifest>\n' \
    >"$AOSP_DIR/.repo/manifests/default.xml"

printf 'base\n' >"$SOURCE_REPO/example.txt"
git -C "$SOURCE_REPO" add example.txt
git -C "$SOURCE_REPO" commit --quiet -m "base"
BASE_COMMIT=$(git -C "$SOURCE_REPO" rev-parse HEAD)
printf 'patched\n' >"$SOURCE_REPO/example.txt"
git -C "$SOURCE_REPO" commit --quiet -am "patch example"
git -C "$SOURCE_REPO" format-patch --quiet -1 --stdout \
    >"$PATCH_ROOT/0001-test.patch"
git -C "$SOURCE_REPO" reset --quiet --hard "$BASE_COMMIT"

cat >"$PATCH_DIR/apply-patch.sh" <<'EOF'
#!/usr/bin/env bash
printf 'apply=%s\n' "$1" >>"$1/patch-flow"
EOF
cat >"$PATCH_DIR/verify-patch-state.sh" <<'EOF'
#!/usr/bin/env bash
printf 'verify=%s depth=%s\n' "$1" "$PATCH_HISTORY_DEPTH" >>"$1/patch-flow"
EOF
chmod 0755 "$PATCH_DIR/apply-patch.sh" "$PATCH_DIR/verify-patch-state.sh"

apply_redroid_patches
[[ "$(sed -n '1p' "$PATCH_FLOW")" == "apply=$AOSP_DIR" ]] ||
    die "Patch application script was not called first"
[[ "$(sed -n '2p' "$PATCH_FLOW")" == \
    "verify=$AOSP_DIR depth=$PATCH_HISTORY_DEPTH" ]] ||
    die "Patch verification script was not called second"

printf 'conflict\n' >"$SOURCE_REPO/example.txt"
git -C "$SOURCE_REPO" commit --quiet -am "create conflict"
CONFLICT_HEAD=$(git -C "$SOURCE_REPO" rev-parse HEAD)
cat >"$PATCH_DIR/apply-patch.sh" <<EOF
#!/usr/bin/env bash
git -C "\$1/system/core" am --reject "$PATCH_ROOT/0001-test.patch" || true
EOF
chmod 0755 "$PATCH_DIR/apply-patch.sh"

GIT_DIR=$(git -C "$SOURCE_REPO" rev-parse --absolute-git-dir)
if AOSP_DIR="$AOSP_DIR" PATCH_DIR="$PATCH_DIR" PATCH_HISTORY_DEPTH=32 \
    /bin/bash -c 'source "$1"; apply_redroid_patches' \
    _ "$BUILDER_DIR/build_floral.sh"; then
    die "Patch wrapper did not reject an unfinished git am operation"
fi
[[ ! -d "$GIT_DIR/rebase-apply" ]] || die "Failed git am state was not removed"
[[ "$(git -C "$SOURCE_REPO" rev-parse HEAD)" == "$CONFLICT_HEAD" ]] ||
    die "Patch cleanup changed the pre-application commit"

REMOVE_LOG="$TEST_ROOT/remove-container"
(
    container_exists() {
        return 0
    }
    docker() {
        printf '%s\n' "$*" >"$REMOVE_LOG"
    }
    BUILDER_STARTED=1
    remove_failed_builder_container
    [[ "$BUILDER_STARTED" == "0" ]] || die "Builder state was not cleared"
)
[[ "$(cat "$REMOVE_LOG")" == "rm --force $BUILDER_CONTAINER" ]] ||
    die "Failed builder container was not forcibly removed"

mkdir -p "$ENVSETUP_ROOT/build"
cat >"$ENVSETUP_ROOT/build/envsetup.sh" <<'EOF'
printf '%s:%s\n' "$TOP" "$ZSH_VERSION" >envsetup-values
lunch() {
    printf 'lunch=%s\n' "$1" >>envsetup-values
}
m() {
    printf 'm=%s\n' "$1" >>envsetup-values
}
EOF

BUILD_COMMAND=$(android_build_script)
(
    unset TOP ZSH_VERSION
    cd "$ENVSETUP_ROOT"
    /bin/bash -lc "$BUILD_COMMAND"
)
[[ "$(sed -n '2p' "$ENVSETUP_ROOT/envsetup-values")" == "lunch=$LUNCH_TARGET" ]] ||
    die "Generated build command did not run lunch"
[[ "$(sed -n '3p' "$ENVSETUP_ROOT/envsetup-values")" == "m=-j$JOBS" ]] ||
    die "Generated build command did not run m"

printf '\nPASS: patch flow and AOSP envsetup compatibility verified\n'
