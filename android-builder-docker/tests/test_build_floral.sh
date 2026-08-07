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
SOURCE_REPO="$AOSP_DIR/system/core"
PATCH_ROOT="$PATCH_DIR/android-test/system/core"
ENVSETUP_ROOT="$TEST_ROOT/envsetup"

mkdir -p "$SOURCE_REPO" "$PATCH_ROOT"
git -C "$SOURCE_REPO" init --quiet
git -C "$SOURCE_REPO" config user.name "Floral Build Test"
git -C "$SOURCE_REPO" config user.email "build-test@floraldroid.invalid"

printf 'base\n' >"$SOURCE_REPO/example.txt"
git -C "$SOURCE_REPO" add example.txt
git -C "$SOURCE_REPO" commit --quiet -m "base"
BASE_COMMIT=$(git -C "$SOURCE_REPO" rev-parse HEAD)

printf 'feature\n' >>"$SOURCE_REPO/example.txt"
git -C "$SOURCE_REPO" commit --quiet -am "add feature"
git -C "$SOURCE_REPO" format-patch --quiet -1 --stdout \
    >"$PATCH_ROOT/0001-add-feature.patch"
git -C "$SOURCE_REPO" reset --quiet --hard "$BASE_COMMIT"

apply_missing_patches android-test
FIRST_HEAD=$(git -C "$SOURCE_REPO" rev-parse HEAD)
[[ "$FIRST_HEAD" != "$BASE_COMMIT" ]] || die "First pass did not apply the patch"
[[ "$(tail -n 1 "$SOURCE_REPO/example.txt")" == "feature" ]] ||
    die "Applied patch did not update the test file"

apply_missing_patches android-test
SECOND_HEAD=$(git -C "$SOURCE_REPO" rev-parse HEAD)
[[ "$SECOND_HEAD" == "$FIRST_HEAD" ]] || die "Second pass applied the patch twice"
[[ "$(git -C "$SOURCE_REPO" rev-list --count HEAD)" == "2" ]] ||
    die "Unexpected commit count after the idempotence test"

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

printf '\nPASS: patch idempotence and AOSP envsetup compatibility verified\n'
