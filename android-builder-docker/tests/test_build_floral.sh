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
PRODUCT_DIR="$AOSP_DIR/out/target/product/redroid_x86_64"
ENVSETUP_ROOT="$TEST_ROOT/envsetup"
FAKE_BIN="$TEST_ROOT/bin"
SOURCE_REPO="$AOSP_DIR/system/core"
PATCH_ROOT="$PATCH_DIR/android-test/system/core"
PATCH_FLOW="$AOSP_DIR/patch-flow"

mkdir -p "$AOSP_DIR/.repo/manifests" "$SOURCE_REPO" "$PATCH_ROOT"
mkdir -p "$FAKE_BIN"
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

cat >"$FAKE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$FAKE_BIN/python3"

BUILD_COMMAND=$(android_build_script)
(
    unset TOP ZSH_VERSION
    cd "$ENVSETUP_ROOT"
    PATH="$FAKE_BIN:$PATH" /bin/bash -c "$BUILD_COMMAND"
)
[[ "$(sed -n '2p' "$ENVSETUP_ROOT/envsetup-values")" == "lunch=$LUNCH_TARGET" ]] ||
    die "Generated build command did not run lunch"
[[ "$(sed -n '3p' "$ENVSETUP_ROOT/envsetup-values")" == "m=-j$JOBS" ]] ||
    die "Generated build command did not run m"

SIGN_EXISTING=0
RELEASE_BUILD=0
SKIP_SYNC=0
SKIP_PATCHES=0
SKIP_IMPORT=0
SKIP_EXPORT=0
parse_args --sign-existing
[[ "$SIGN_EXISTING" == 1 && "$RELEASE_BUILD" == 1 && "$SKIP_BUILD" == 0 ]] ||
    die "Sign-existing mode did not select release signing without a build skip"
[[ "$SKIP_SYNC" == 1 && "$SKIP_PATCHES" == 1 &&
    "$SKIP_IMPORT" == 1 && "$SKIP_EXPORT" == 1 ]] ||
    die "Sign-existing mode did not disable unrelated pipeline stages"

RELEASE_BUILD=1
SIGN_EXISTING=0
RELEASE_LUNCH_TARGET=redroid_x86_64-user
RELEASE_KEY_DIR="$TEST_ROOT/release-keys"
RELEASE_OUTPUT_DIR="$TEST_ROOT/release-output"
RELEASE_KEY_PASSWORD_FILE="$TEST_ROOT/release-password"
printf 'test-release-password\n' >"$RELEASE_KEY_PASSWORD_FILE"
chmod 0600 "$RELEASE_KEY_PASSWORD_FILE"
configure_release
[[ "$LUNCH_TARGET" == "$RELEASE_LUNCH_TARGET" ]] ||
    die "Release mode did not select the user lunch target"
RELEASE_BUILD_COMMAND=$(android_build_script)
printf '%s\n' "$RELEASE_BUILD_COMMAND" | rg -q 'target-files-package otatools-package' ||
    die "Release build did not request target-files and OTA tools"
RELEASE_KEY_SCRIPT=$(release_key_generation_script)
printf '%s\n' "$RELEASE_KEY_SCRIPT" | bash -n
printf '%s\n' "$RELEASE_KEY_SCRIPT" | rg -q 'floral-release-password' ||
    die "Release key generation did not use the mounted password secret"
RELEASE_SIGNING_SCRIPT=$(release_signing_script)
printf '%s\n' "$RELEASE_SIGNING_SCRIPT" | bash -n
printf '%s\n' "$RELEASE_SIGNING_SCRIPT" | rg -q 'sign_target_files_apks' ||
    die "Release signing command was not generated"
printf '%s\n' "$RELEASE_SIGNING_SCRIPT" |
    rg -q 'export PATH=/usr/lib/jvm/java-21-openjdk-amd64/bin:' ||
    die "Release signing command did not restore the AOSP JDK PATH"
printf '%s\n' "$RELEASE_SIGNING_SCRIPT" |
    rg -q '/src/out/soong/host/linux-x86/bin:' ||
    die "Release signing command did not restore the Soong host tools PATH"
printf '%s\n' "$RELEASE_SIGNING_SCRIPT" | rg -q -- '--extra_apks' ||
    die "Release APEX container key override was not generated"

prepare_release_password
[[ -f "$RELEASE_PASSWORD_TMP" ]] || die "Release password secret was not created"
[[ "$(stat -c '%a' "$RELEASE_PASSWORD_TMP")" == "600" ]] ||
    die "Release password secret has unsafe permissions"
[[ "$(<"$RELEASE_PASSWORD_TMP")" == "test-release-password" ]] ||
    die "Release password secret contents changed"
clear_release_password

printf '\nPASS: patch flow, release signing flow, and AOSP envsetup compatibility verified\n'
