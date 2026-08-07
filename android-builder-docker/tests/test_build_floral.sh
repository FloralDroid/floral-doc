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

printf '\nPASS: missing patch applied once and existing patch skipped\n'
