#!/usr/bin/env bash

set -Eeuo pipefail

#####################
# Configuration
#####################

AOSP_DIR="${AOSP_DIR:-${HOME}/floral}"
LOCAL_MANIFEST_URL="${LOCAL_MANIFEST_URL:-https://github.com/FloralDroid/local_manifests.git}"
LOCAL_MANIFEST_BRANCH="${LOCAL_MANIFEST_BRANCH:-12.0.0}"
LOCAL_MANIFEST_DIR="${LOCAL_MANIFEST_DIR:-${AOSP_DIR}/.repo/local_manifests}"

PATCH_URL="${PATCH_URL:-https://github.com/FloralDroid/redroid-patches.git}"
PATCH_BRANCH="${PATCH_BRANCH:-master}"
PATCH_DIR="${PATCH_DIR:-${HOME}/redroid-patches}"
PATCH_HISTORY_DEPTH="${PATCH_HISTORY_DEPTH:-256}"

BUILDER_IMAGE="${BUILDER_IMAGE:-floral-builder}"
BUILDER_CONTAINER="${BUILDER_CONTAINER:-floral-builder}"

PRODUCT_NAME="${PRODUCT_NAME:-redroid_x86_64}"
LUNCH_TARGET="${LUNCH_TARGET:-redroid_x86_64-userdebug}"
PRODUCT_DIR="${PRODUCT_DIR:-${AOSP_DIR}/out/target/product/${PRODUCT_NAME}}"
BUILD_LOG="${BUILD_LOG:-${AOSP_DIR}/out/floral-build.log}"

RELEASE_LUNCH_TARGET="${RELEASE_LUNCH_TARGET:-${PRODUCT_NAME}-user}"
RELEASE_KEY_DIR="${RELEASE_KEY_DIR:-${HOME}/.floral/release-keys}"
RELEASE_KEY_PASSWORD_FILE="${RELEASE_KEY_PASSWORD_FILE:-}"
RELEASE_KEY_SUBJECT="${RELEASE_KEY_SUBJECT:-/O=FloralDroid/OU=Release/CN=FloralDroid Release}"
RELEASE_OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-${AOSP_DIR}/out/release/${PRODUCT_NAME}}"

RUNTIME_IMAGE="${RUNTIME_IMAGE:-floral:12.0.0}"
RUNTIME_PLATFORM="${RUNTIME_PLATFORM:-linux/amd64}"
EXPORT_FILE="${EXPORT_FILE:-${HOME}/floral-12.0.0.tar.gz}"

JOBS="${JOBS:-$(nproc)}"

SKIP_SYNC=0
SKIP_PATCHES=0
SKIP_BUILD=0
SKIP_IMPORT=0
SKIP_EXPORT=0
REPLACE_FAILED_CONTAINER=0
KEEP_BUILDER_CONTAINER=0
RELEASE_BUILD=0
SIGN_EXISTING=0

#####################
# State and helpers
#####################

MOUNT_ROOT=""
SYSTEM_MOUNT=""
VENDOR_MOUNT=""
EXPORT_TMP=""
CHECKSUM_TMP=""
RELEASE_PASSWORD_TMP=""
PATCH_APPLICATION_ACTIVE=0
BUILDER_STARTED=0
IMAGE_DIR="$PRODUCT_DIR"
SUDO=()

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

warn() {
    printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}

die() {
    printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

usage() {
    cat <<'EOF'
Usage: build_floral.sh [options]

Synchronize FloralDroid sources, apply the complete ReDroid patch set, build
inside the existing floral-builder image, import the runtime image, and export
it as a gzip-compressed Docker archive.

Options:
  --release                   Build the user variant and sign release images
  --sign-existing             Sign existing target-files without rebuilding AOSP
  --skip-sync                 Do not update manifests, sources, or patch repo
  --skip-patches              Do not verify or apply ReDroid patches
  --skip-build                Reuse existing system.img and vendor.img
  --skip-import               Reuse an existing Docker runtime image
  --skip-export               Do not export the Docker runtime image
  --replace-failed-container  Remove an existing builder container
  --keep-builder-container    Keep the builder container after a successful build
  -h, --help                  Show this help

Failed build containers are removed automatically. The builder image, bound
AOSP source tree, incremental output, and host build log are retained.

Configuration is provided through the environment variables declared at the
top of this script. Common overrides include AOSP_DIR, JOBS, LUNCH_TARGET,
BUILDER_IMAGE, RUNTIME_IMAGE, RUNTIME_PLATFORM, BUILD_LOG, and EXPORT_FILE.
Release overrides include RELEASE_KEY_DIR, RELEASE_KEY_PASSWORD_FILE,
RELEASE_KEY_SUBJECT, RELEASE_LUNCH_TARGET, and RELEASE_OUTPUT_DIR.
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --release) RELEASE_BUILD=1 ;;
            --sign-existing) SIGN_EXISTING=1; RELEASE_BUILD=1 ;;
            --skip-sync) SKIP_SYNC=1 ;;
            --skip-patches) SKIP_PATCHES=1 ;;
            --skip-build) SKIP_BUILD=1 ;;
            --skip-import) SKIP_IMPORT=1 ;;
            --skip-export) SKIP_EXPORT=1 ;;
            --replace-failed-container) REPLACE_FAILED_CONTAINER=1 ;;
            --keep-builder-container) KEEP_BUILDER_CONTAINER=1 ;;
            -h|--help)
                usage
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done

    if ((SIGN_EXISTING)); then
        ((SKIP_BUILD == 0)) || die "--sign-existing cannot be combined with --skip-build"
        SKIP_SYNC=1
        SKIP_PATCHES=1
        SKIP_IMPORT=1
        SKIP_EXPORT=1
    fi
}

run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

container_exists() {
    docker container inspect "$BUILDER_CONTAINER" >/dev/null 2>&1
}

container_state() {
    docker container inspect --format '{{.State.Status}}' "$BUILDER_CONTAINER"
}

remove_failed_builder_container() {
    if ! container_exists; then
        BUILDER_STARTED=0
        return
    fi

    warn "Remove failed builder container: $BUILDER_CONTAINER"
    if ! docker rm --force "$BUILDER_CONTAINER" >/dev/null; then
        warn "Cannot remove failed builder container: $BUILDER_CONTAINER"
        return 1
    fi
    BUILDER_STARTED=0
}

unmount_images() {
    local failed=0

    if [[ -n "$VENDOR_MOUNT" ]] && mountpoint -q "$VENDOR_MOUNT"; then
        "${SUDO[@]}" umount "$VENDOR_MOUNT" || failed=1
    fi
    if [[ -n "$SYSTEM_MOUNT" ]] && mountpoint -q "$SYSTEM_MOUNT"; then
        "${SUDO[@]}" umount "$SYSTEM_MOUNT" || failed=1
    fi

    if [[ -n "$MOUNT_ROOT" && -d "$MOUNT_ROOT" ]]; then
        rmdir "$VENDOR_MOUNT" "$SYSTEM_MOUNT" "$MOUNT_ROOT" 2>/dev/null || failed=1
    fi

    if ((failed == 0)); then
        MOUNT_ROOT=""
        SYSTEM_MOUNT=""
        VENDOR_MOUNT=""
    fi
    return "$failed"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e

    if ((PATCH_APPLICATION_ACTIVE)); then
        abort_redroid_patch_operations ||
            warn "One or more ReDroid patch operations require manual cleanup"
    fi

    if ! unmount_images; then
        warn "One or more image mounts require manual cleanup under $MOUNT_ROOT"
    fi

    if [[ -n "$EXPORT_TMP" && -f "$EXPORT_TMP" ]]; then
        rm -f -- "$EXPORT_TMP"
    fi
    if [[ -n "$CHECKSUM_TMP" && -f "$CHECKSUM_TMP" ]]; then
        rm -f -- "$CHECKSUM_TMP"
    fi
    if [[ -n "$RELEASE_PASSWORD_TMP" && -f "$RELEASE_PASSWORD_TMP" ]]; then
        rm -f -- "$RELEASE_PASSWORD_TMP"
    fi
    if ((rc != 0 && BUILDER_STARTED)); then
        remove_failed_builder_container || true
        if [[ -f "$BUILD_LOG" ]]; then
            printf '  build log: %s\n' "$BUILD_LOG" >&2
        fi
    fi

    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

#####################
# Preflight
#####################

configure_sudo() {
    if ((EUID == 0)); then
        SUDO=()
    else
        need_cmd sudo
        SUDO=(sudo)
    fi
}

configure_release() {
    if ((!RELEASE_BUILD)); then
        return
    fi

    LUNCH_TARGET="$RELEASE_LUNCH_TARGET"
    IMAGE_DIR="$RELEASE_OUTPUT_DIR/images"
}

prepare_release_password() {
    local -a password_lines=()
    local password
    local confirmation
    local mode

    mkdir -p "$RELEASE_KEY_DIR" "$RELEASE_OUTPUT_DIR"
    chmod 0700 "$RELEASE_KEY_DIR"

    if [[ -n "$RELEASE_KEY_PASSWORD_FILE" ]]; then
        [[ -f "$RELEASE_KEY_PASSWORD_FILE" && ! -L "$RELEASE_KEY_PASSWORD_FILE" ]] ||
            die "Release key password file must be a regular file"
        mode=$(stat -c '%a' "$RELEASE_KEY_PASSWORD_FILE")
        (((8#$mode & 077) == 0)) ||
            die "Release key password file must not be accessible by group or others"
        mapfile -t password_lines <"$RELEASE_KEY_PASSWORD_FILE"
        ((${#password_lines[@]} == 1)) ||
            die "Release key password file must contain exactly one line"
        password=${password_lines[0]}
    else
        [[ -t 0 ]] ||
            die "Set RELEASE_KEY_PASSWORD_FILE for a non-interactive release build"
        read -r -s -p "Release key password: " password
        printf '\n' >&2
        read -r -s -p "Confirm release key password: " confirmation
        printf '\n' >&2
        [[ "$password" == "$confirmation" ]] || die "Release key passwords do not match"
        unset confirmation
    fi

    [[ -n "$password" ]] || die "Release key password must not be empty"
    [[ "$password" != *']]]'* ]] || die "Release key password must not contain ]]]"

    RELEASE_PASSWORD_TMP=$(mktemp /tmp/floral-release-password.XXXXXX)
    chmod 0600 "$RELEASE_PASSWORD_TMP"
    printf '%s\n' "$password" >"$RELEASE_PASSWORD_TMP"
    unset password
    password_lines=()
}

clear_release_password() {
    if [[ -n "$RELEASE_PASSWORD_TMP" ]]; then
        rm -f -- "$RELEASE_PASSWORD_TMP"
        RELEASE_PASSWORD_TMP=""
    fi
}

validate_configuration() {
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
    [[ "$PATCH_HISTORY_DEPTH" =~ ^[1-9][0-9]*$ ]] ||
        die "PATCH_HISTORY_DEPTH must be a positive integer"
    [[ "$PRODUCT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid PRODUCT_NAME"
    [[ "$LUNCH_TARGET" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid LUNCH_TARGET"
    [[ "$BUILDER_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] ||
        die "Invalid BUILDER_CONTAINER"

    if ((RELEASE_BUILD)); then
        [[ "$RELEASE_LUNCH_TARGET" =~ ^[A-Za-z0-9._-]+-user$ ]] ||
            die "RELEASE_LUNCH_TARGET must select a user build"
        [[ -n "$RELEASE_KEY_SUBJECT" && "$RELEASE_KEY_SUBJECT" != *$'\n'* ]] ||
            die "Invalid RELEASE_KEY_SUBJECT"
        [[ "$RELEASE_KEY_DIR" != *:* ]] || die "RELEASE_KEY_DIR must not contain ':'"
        [[ "$RELEASE_OUTPUT_DIR" != *:* ]] || die "RELEASE_OUTPUT_DIR must not contain ':'"
        [[ "$RELEASE_KEY_DIR" == /* && "$RELEASE_OUTPUT_DIR" == /* ]] ||
            die "Release key and output directories must be absolute paths"
        [[ "$PRODUCT_DIR" == "$AOSP_DIR"/* ]] ||
            die "Release PRODUCT_DIR must be inside AOSP_DIR"
        if ((SIGN_EXISTING)); then
            [[ -d "$PRODUCT_DIR/obj/PACKAGING/target_files_intermediates" ]] ||
                die "Existing target-files directory not found under $PRODUCT_DIR"
        else
            ((!SKIP_BUILD)) || die "--release requires a fresh target-files build"
        fi
        if ((KEEP_BUILDER_CONTAINER)); then
            die "--keep-builder-container is not supported with --release"
        fi
    fi

    [[ -d "$AOSP_DIR/.repo" ]] ||
        die "$AOSP_DIR is not an AOSP source tree initialized with repo"

    need_cmd git
    need_cmd mktemp

    if ((!SKIP_SYNC)); then
        if command -v repo >/dev/null 2>&1; then
            REPO=(repo)
        elif [[ -x "$AOSP_DIR/.repo/repo/repo" ]]; then
            REPO=("$AOSP_DIR/.repo/repo/repo")
        else
            die "Missing command: repo"
        fi
    else
        REPO=()
    fi

    if ((!SKIP_PATCHES)); then
        need_cmd xmllint
    fi

    if ((!SKIP_BUILD || !SKIP_IMPORT || !SKIP_EXPORT)); then
        need_cmd docker
        docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
    fi

    if ((!SKIP_BUILD)); then
        need_cmd tee
        if ((RELEASE_BUILD)); then
            need_cmd stat
        fi
        docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 ||
            die "Builder image not found: $BUILDER_IMAGE"
    fi

    if ((!SKIP_IMPORT)); then
        need_cmd mount
        need_cmd mountpoint
        need_cmd tar
    fi

    if ((!SKIP_EXPORT)); then
        need_cmd gzip
        need_cmd sha256sum
    fi
}

#####################
# Source synchronization
#####################

update_checkout() {
    local directory=$1
    local url=$2
    local branch=$3

    if [[ -d "$directory/.git" ]]; then
        # These checkouts are build inputs. Reset them so force-pushed branches
        # and files left by a previous failed run cannot affect the next sync.
        run git -C "$directory" fetch --prune origin "$branch"
        run git -C "$directory" checkout -B "$branch" "origin/$branch"
        run git -C "$directory" reset --hard "origin/$branch"
        run git -C "$directory" clean -fdx
    elif [[ -e "$directory" ]]; then
        die "$directory exists but is not a Git repository"
    else
        run git clone --branch "$branch" --single-branch "$url" "$directory"
    fi
}

sync_sources() {
    log "Update FloralDroid local manifests"
    update_checkout "$LOCAL_MANIFEST_DIR" "$LOCAL_MANIFEST_URL" \
        "$LOCAL_MANIFEST_BRANCH"

    log "Sync AOSP and FloralDroid sources (jobs=$JOBS)"
    (
        cd "$AOSP_DIR"
        # Patch application creates local commits. Remove those commits and
        # generated files before syncing back to the manifest revisions.
        run "${REPO[@]}" forall -c 'git reset --hard && git clean -fdx'
        run "${REPO[@]}" sync -c -d --force-sync -j"$JOBS"
    )

    log "Update ReDroid patch repository"
    update_checkout "$PATCH_DIR" "$PATCH_URL" "$PATCH_BRANCH"
}

#####################
# ReDroid patch application
#####################

redroid_patch_root() {
    local revision
    local tag
    local patch_root

    revision=$(xmllint --xpath 'string(/manifest/default/@revision)' \
        "$AOSP_DIR/.repo/manifests/default.xml")
    tag=${revision##*/}
    patch_root="$PATCH_DIR/$tag"

    [[ -n "$tag" ]] || die "Cannot detect AOSP revision from the manifest"
    [[ -d "$patch_root" ]] || die "Patch directory does not exist: $patch_root"
    printf '%s\n' "$patch_root"
}

redroid_patch_operations_clean() {
    local patch_root
    local patch_directory
    local project
    local source_repo
    local git_dir
    local failed=0

    patch_root=$(redroid_patch_root)
    while IFS= read -r patch_directory; do
        project=${patch_directory#"$patch_root"/}
        source_repo="$AOSP_DIR/$project"
        [[ -d "$source_repo/.git" ]] || continue
        git_dir=$(git -C "$source_repo" rev-parse --absolute-git-dir)

        if [[ -d "$git_dir/rebase-apply" || -d "$git_dir/rebase-merge" ]]; then
            warn "Unfinished Git operation in patch project: $project"
            failed=1
        fi
    done < <(find "$patch_root" -type f -name '*.patch' -printf '%h\n' | sort -u)

    return "$failed"
}

abort_redroid_patch_operations() {
    local patch_root
    local patch_directory
    local project
    local source_repo
    local git_dir
    local failed=0

    patch_root=$(redroid_patch_root)
    while IFS= read -r patch_directory; do
        project=${patch_directory#"$patch_root"/}
        source_repo="$AOSP_DIR/$project"
        [[ -d "$source_repo/.git" ]] || continue
        git_dir=$(git -C "$source_repo" rev-parse --absolute-git-dir)

        if [[ -f "$git_dir/rebase-apply/applying" ]]; then
            warn "Abort unfinished ReDroid git am operation: $project"
            git -C "$source_repo" am --abort || failed=1
        elif [[ -d "$git_dir/rebase-apply" || -d "$git_dir/rebase-merge" ]]; then
            warn "Abort unfinished ReDroid rebase operation: $project"
            git -C "$source_repo" rebase --abort || failed=1
        fi
    done < <(find "$patch_root" -type f -name '*.patch' -printf '%h\n' | sort -u)

    PATCH_APPLICATION_ACTIVE=0
    return "$failed"
}

apply_redroid_patches() {
    local apply_script="$PATCH_DIR/apply-patch.sh"
    local verify_script="$PATCH_DIR/verify-patch-state.sh"

    [[ -x "$apply_script" ]] || die "Patch application script not found: $apply_script"
    [[ -x "$verify_script" ]] || die "Patch verification script not found: $verify_script"
    redroid_patch_operations_clean ||
        die "Clean unfinished Git operations before applying ReDroid patches"

    log "Apply complete ReDroid patch set after source sync"
    PATCH_APPLICATION_ACTIVE=1
    run "$apply_script" "$AOSP_DIR"

    if ! redroid_patch_operations_clean; then
        abort_redroid_patch_operations || true
        die "ReDroid patch application left unfinished Git operations"
    fi

    # apply-patch.sh reports individual project errors without propagating a
    # nonzero status, so verification is mandatory before starting the build.
    log "Verify ReDroid patch state"
    if ! PATCH_HISTORY_DEPTH="$PATCH_HISTORY_DEPTH" \
        "$verify_script" "$AOSP_DIR"; then
        abort_redroid_patch_operations || true
        die "ReDroid patch verification failed"
    fi
    PATCH_APPLICATION_ACTIVE=0
}

#####################
# Container build
#####################

prepare_builder_container() {
    local state
    local pid1_args=""
    local attempt

    if container_exists; then
        state=$(container_state)
        if ((!REPLACE_FAILED_CONTAINER)); then
            die "Builder container exists (state=$state); inspect it or rerun with" \
                "--replace-failed-container"
        fi
        log "Remove previous builder container (state=$state)"
        run docker rm --force "$BUILDER_CONTAINER"
    fi

    log "Start builder container through its default entrypoint"
    local docker_args=(
        docker run --detach --interactive --tty
        --hostname "$BUILDER_CONTAINER"
        --name "$BUILDER_CONTAINER"
        --workdir /src
        --volume "$AOSP_DIR:/src"
    )
    if ((RELEASE_BUILD)); then
        docker_args+=(
            --volume "$RELEASE_KEY_DIR:/release-keys"
            --volume "$RELEASE_OUTPUT_DIR:/release-output"
            --volume "$RELEASE_PASSWORD_TMP:/run/secrets/floral-release-password:ro"
        )
    fi
    local proxy_name
    for proxy_name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
        if [[ -n "${!proxy_name:-}" ]]; then
            docker_args+=(--env "$proxy_name")
        fi
    done
    docker_args+=("$BUILDER_IMAGE")
    run "${docker_args[@]}"
    BUILDER_STARTED=1

    # The current builder entrypoint configures compatibility libraries and
    # then replaces PID 1 with the unprivileged interactive shell.
    for ((attempt = 1; attempt <= 30; ++attempt)); do
        state=$(container_state 2>/dev/null || true)
        [[ "$state" == "running" ]] ||
            die "Builder container stopped during initialization (state=$state)"

        pid1_args=$(docker exec "$BUILDER_CONTAINER" ps -p 1 -o args= 2>/dev/null || true)
        if [[ "$pid1_args" == *"bash -i"* ]]; then
            return
        fi
        sleep 1
    done

    die "Builder entrypoint did not become ready; PID 1 is: $pid1_args"
}

stream_command_to_log() {
    local log_file=$1
    shift
    local command_rc

    mkdir -p "$(dirname "$log_file")"
    : >"$log_file"

    "$@" 2>&1 | tee "$log_file"
    command_rc=${PIPESTATUS[0]}
    return "$command_rc"
}

report_builder_failure() {
    local build_exit_code=$1
    local state
    local container_exit_code
    local oom_killed
    local error

    state=$(docker inspect --format '{{.State.Status}}' \
        "$BUILDER_CONTAINER" 2>/dev/null || true)
    container_exit_code=$(docker inspect --format '{{.State.ExitCode}}' \
        "$BUILDER_CONTAINER" 2>/dev/null || true)
    oom_killed=$(docker inspect --format '{{.State.OOMKilled}}' \
        "$BUILDER_CONTAINER" 2>/dev/null || true)
    error=$(docker inspect --format '{{.State.Error}}' \
        "$BUILDER_CONTAINER" 2>/dev/null || true)

    warn "Builder failed: build_exit_code=$build_exit_code container_state=$state" \
        "container_exit_code=$container_exit_code oom_killed=$oom_killed error=$error"
}

android_build_script() {
    local lunch_target_q
    local build_goal=""

    printf -v lunch_target_q '%q' "$LUNCH_TARGET"
    if ((RELEASE_BUILD)); then
        build_goal=' target-files-package otatools-package'
    fi

    # Android 12 envsetup reads optional variables such as TOP and ZSH_VERSION.
    # Keep nounset disabled only in the shell that sources the AOSP environment.
    printf '%s\n' \
        'set -Ee -o pipefail' \
        'source build/envsetup.sh' \
        "lunch $lunch_target_q" \
        'unset PYTHONHOME' \
        'export PYTHONPATH=/usr/lib/python3/dist-packages:/src/development/python-packages' \
        'python3 -c "import mako.template"' \
        "m -j$JOBS$build_goal"
}

release_key_generation_script() {
    local subject_q

    printf -v subject_q '%q' "$RELEASE_KEY_SUBJECT"
    cat <<EOF
set -Eeuo pipefail
umask 077
cd /release-keys
    [[ -s /run/secrets/floral-release-password ]] || {
        printf 'Release key password secret is missing\\n' >&2
        exit 1
    }
password=\$(</run/secrets/floral-release-password)
for key in releasekey platform shared media networkstack; do
    if [[ -e "\$key.pk8" || -e "\$key.x509.pem" ]]; then
        [[ -f "\$key.pk8" && -f "\$key.x509.pem" ]] || {
            printf 'Incomplete release key pair: %s\\n' "\$key" >&2
            exit 1
        }
    else
        tmpdir=\$(mktemp -d /tmp/floral-release-key.XXXXXX)
        chmod 0700 "\$tmpdir"
        openssl genrsa -aes256 \
            -passout fd:3 3< <(printf '%s' "\$password") \
            -out "\$tmpdir/key.pem" 2048
        openssl req -new -x509 -sha256 \
            -key "\$tmpdir/key.pem" \
            -passin fd:3 3< <(printf '%s' "\$password") \
            -out "\$key.x509.pem" \
            -days 10000 \
            -subj $subject_q
        openssl pkcs8 \
            -in "\$tmpdir/key.pem" \
            -passin fd:3 3< <(printf '%s' "\$password") \
            -topk8 \
            -outform DER \
            -out "\$key.pk8" \
            -passout fd:4 4< <(printf '%s' "\$password")
        rm -rf -- "\$tmpdir"
    fi
    openssl pkcs8 -inform DER -in "\$key.pk8" \
        -passin fd:3 3< <(printf '%s' "\$password") -out /dev/null
    openssl x509 -in "\$key.x509.pem" -noout
    chmod 0600 "\$key.pk8" "\$key.x509.pem"
done
unset password
EOF
}

release_signing_script() {
    local product_name_q
    local product_dir_q
    local product_dir_in_container

    printf -v product_name_q '%q' "$PRODUCT_NAME"
    product_dir_in_container="/src/${PRODUCT_DIR#"$AOSP_DIR"/}"
    printf -v product_dir_q '%q' "$product_dir_in_container"
    cat <<EOF
set -Eeuo pipefail
umask 077
export PATH=/usr/lib/jvm/java-21-openjdk-amd64/bin:/src/out/soong/host/linux-x86/bin:\$PATH
product_name=$product_name_q
product_dir=$product_dir_q
target_files_dir="\$product_dir/obj/PACKAGING/target_files_intermediates"
shopt -s nullglob
target_files=("\$target_files_dir"/"\$product_name"-target_files-*.zip)
((\${#target_files[@]} > 0)) || {
    printf 'Unsigned target-files package not found under %s\\n' "\$target_files_dir" >&2
    exit 1
}
unsigned_target_files=""
for candidate in "\${target_files[@]}"; do
    if [[ -z "\$unsigned_target_files" || "\$candidate" -nt "\$unsigned_target_files" ]]; then
        unsigned_target_files="\$candidate"
    fi
done
signed_target_files=/release-output/signed-target_files.zip
signed_images=/release-output/signed-img.zip
signed_target_files_tmp="\$signed_target_files.tmp"
signed_images_tmp="\$signed_images.tmp"
images_tmp=/release-output/images.tmp
password_file=\$(mktemp /tmp/floral-android-passwords.XXXXXX)
cleanup_release_signing() {
    rm -f -- "\$password_file" "\$signed_target_files_tmp" "\$signed_images_tmp"
    rm -rf -- "\$images_tmp"
}
trap cleanup_release_signing EXIT

password=\$(</run/secrets/floral-release-password)
for key in releasekey platform shared media networkstack; do
    printf '[[[  %s  ]]] /release-keys/%s\\n' "\$password" "\$key"
done >"\$password_file"
unset password
chmod 0600 "\$password_file"
export ANDROID_PW_FILE="\$password_file"

signing_args=(-o -d /release-keys)
mkdir -p /release-keys/apex
chmod 0700 /release-keys/apex
while IFS= read -r apex_name; do
    [[ -n "\$apex_name" ]] || continue
    [[ "\$apex_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
        printf 'Invalid APEX filename in target-files: %s\\n' "\$apex_name" >&2
        exit 1
    }
    apex_key="/release-keys/apex/\$apex_name.pem"
    if [[ ! -e "\$apex_key" ]]; then
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "\$apex_key"
    fi
    [[ -f "\$apex_key" ]] || {
        printf 'Invalid APEX payload key path: %s\\n' "\$apex_key" >&2
        exit 1
    }
    openssl pkey -in "\$apex_key" -check -noout
    chmod 0600 "\$apex_key"
    signing_args+=(--extra_apex_payload_key "\$apex_name=\$apex_key")
    signing_args+=(--extra_apks "\$apex_name=/release-keys/releasekey")
done < <(python3 -c '
import re
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as target_files:
    data = target_files.read("META/apexkeys.txt").decode()
for line in data.splitlines():
    fields = dict(re.findall(r"(\\w+)=\"([^\\"]*)\"", line))
    if (fields.get("private_key") not in (None, "PRESIGNED") and
            fields.get("container_private_key") != "PRESIGNED"):
        print(fields["name"])
' "\$unsigned_target_files" | sort -u)

/src/out/host/linux-x86/bin/sign_target_files_apks \
    "\${signing_args[@]}" \
    "\$unsigned_target_files" \
    "\$signed_target_files_tmp"
/src/out/host/linux-x86/bin/img_from_target_files \
    "\$signed_target_files_tmp" \
    "\$signed_images_tmp"

unzip -p "\$signed_target_files_tmp" SYSTEM/build.prop | \
    grep -qx 'ro.build.tags=release-keys'
rm -rf -- "\$images_tmp"
mkdir -p "\$images_tmp"
unzip -q "\$signed_images_tmp" system.img vendor.img -d "\$images_tmp"
[[ -f "\$images_tmp/system.img" && -f "\$images_tmp/vendor.img" ]]

mv -f -- "\$signed_target_files_tmp" "\$signed_target_files"
mv -f -- "\$signed_images_tmp" "\$signed_images"
rm -rf -- /release-output/images
mv -- "\$images_tmp" /release-output/images
trap - EXIT
rm -f -- "\$password_file"
EOF
}

generate_release_keys() {
    local builder_user=$1
    local builder_home=$2
    local key_script

    key_script=$(release_key_generation_script)
    log "Generate or verify release signing keys in $RELEASE_KEY_DIR"
    run docker exec \
        --user "$builder_user" \
        --env "HOME=$builder_home" \
        --env "USER=$builder_user" \
        --workdir /src \
        "$BUILDER_CONTAINER" \
        /bin/bash -lc "$key_script"
}

sign_release_target_files() {
    local builder_user=$1
    local builder_home=$2
    local signing_script

    signing_script=$(release_signing_script)
    log "Sign target-files and create release images"
    run docker exec \
        --user "$builder_user" \
        --env "HOME=$builder_home" \
        --env "USER=$builder_user" \
        --workdir /src \
        "$BUILDER_CONTAINER" \
        /bin/bash -lc "$signing_script"
}

build_android() {
    local builder_user
    local passwd_entry
    local builder_home
    local build_script
    local build_rc

    prepare_builder_container

    builder_user=$(docker exec "$BUILDER_CONTAINER" cat /root/builder-user)
    [[ "$builder_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] ||
        die "Builder image returned an invalid user: $builder_user"

    passwd_entry=$(docker exec "$BUILDER_CONTAINER" getent passwd "$builder_user")
    [[ -n "$passwd_entry" ]] || die "Builder user is missing from /etc/passwd: $builder_user"
    builder_home=$(cut -d: -f6 <<<"$passwd_entry")
    [[ -n "$builder_home" ]] || die "Cannot determine home directory for $builder_user"

    log "Verify builder Python dependencies"
    run docker exec \
        --user "$builder_user" \
        --env "HOME=$builder_home" \
        --env "USER=$builder_user" \
        "$BUILDER_CONTAINER" \
        python -c 'import mako.template'

    if ((RELEASE_BUILD)); then
        generate_release_keys "$builder_user" "$builder_home"
    fi

    if ((SIGN_EXISTING)); then
        log "Sign existing target-files in $BUILDER_CONTAINER"
    else
        build_script=$(android_build_script)

        log "Build $LUNCH_TARGET in $BUILDER_CONTAINER (jobs=$JOBS)"
        printf 'Build log: %s\n' "$BUILD_LOG"

        if stream_command_to_log "$BUILD_LOG" \
            docker exec \
                --user "$builder_user" \
                --env "HOME=$builder_home" \
                --env "USER=$builder_user" \
                --workdir /src \
                "$BUILDER_CONTAINER" \
                /bin/bash -lc "$build_script"; then
            build_rc=0
        else
            build_rc=$?
        fi
        if ((build_rc != 0)); then
            report_builder_failure "$build_rc"
            die "Android build failed; see the host build log"
        fi
    fi

    if ((RELEASE_BUILD)); then
        sign_release_target_files "$builder_user" "$builder_home"
    fi

    if ((KEEP_BUILDER_CONTAINER)); then
        log "Build succeeded; builder container kept: $BUILDER_CONTAINER"
        BUILDER_STARTED=0
        return
    fi

    log "Build succeeded; remove builder container"
    run docker stop --time 10 "$BUILDER_CONTAINER"
    run docker rm "$BUILDER_CONTAINER"
    BUILDER_STARTED=0
    clear_release_password
}

#####################
# Runtime image import
#####################

mount_images() {
    local system_image="$IMAGE_DIR/system.img"
    local vendor_image="$IMAGE_DIR/vendor.img"

    [[ -f "$system_image" ]] || die "Build output not found: $system_image"
    [[ -f "$vendor_image" ]] || die "Build output not found: $vendor_image"

    MOUNT_ROOT=$(mktemp -d /tmp/floral-import.XXXXXX)
    SYSTEM_MOUNT="$MOUNT_ROOT/system"
    VENDOR_MOUNT="$MOUNT_ROOT/vendor"
    mkdir -p "$SYSTEM_MOUNT" "$VENDOR_MOUNT"

    run "${SUDO[@]}" mount -o loop,ro "$system_image" "$SYSTEM_MOUNT"
    run "${SUDO[@]}" mount -o loop,ro "$vendor_image" "$VENDOR_MOUNT"
}

import_runtime_image() {
    local -a pipeline_status
    local tar_rc
    local import_rc
    local import_command=(
        docker import
        --change 'ENTRYPOINT ["/init", "androidboot.hardware=floral"]'
    )

    if [[ -n "$RUNTIME_PLATFORM" ]]; then
        import_command+=(--platform "$RUNTIME_PLATFORM")
    fi
    import_command+=(- "$RUNTIME_IMAGE")

    log "Mount system.img and vendor.img"
    mount_images

    log "Import Docker runtime image: $RUNTIME_IMAGE"
    set +e
    "${SUDO[@]}" tar \
        --xattrs \
        --xattrs-include='*' \
        -C "$MOUNT_ROOT" \
        -c vendor \
        -C "$SYSTEM_MOUNT" \
        --exclude='./vendor' \
        . |
        "${import_command[@]}"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    tar_rc=${pipeline_status[0]}
    import_rc=${pipeline_status[1]}

    ((tar_rc == 0)) || die "Root filesystem archive failed with exit code $tar_rc"
    ((import_rc == 0)) || die "Docker import failed with exit code $import_rc"

    unmount_images || die "Cannot unmount imported Android images"
}

#####################
# Docker image export
#####################

export_runtime_image() {
    local -a pipeline_status
    local save_rc
    local gzip_rc

    docker image inspect "$RUNTIME_IMAGE" >/dev/null 2>&1 ||
        die "Runtime image not found: $RUNTIME_IMAGE"

    log "Export Docker image: $EXPORT_FILE"
    mkdir -p "$(dirname "$EXPORT_FILE")"
    EXPORT_TMP=$(mktemp "${EXPORT_FILE}.tmp.XXXXXX")

    set +e
    docker save "$RUNTIME_IMAGE" | gzip -1 >"$EXPORT_TMP"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    save_rc=${pipeline_status[0]}
    gzip_rc=${pipeline_status[1]}

    ((save_rc == 0)) || die "Docker save failed with exit code $save_rc"
    ((gzip_rc == 0)) || die "gzip failed with exit code $gzip_rc"

    mv -f -- "$EXPORT_TMP" "$EXPORT_FILE"
    EXPORT_TMP=""

    CHECKSUM_TMP=$(mktemp "${EXPORT_FILE}.sha256.tmp.XXXXXX")
    sha256sum "$EXPORT_FILE" >"$CHECKSUM_TMP"
    mv -f -- "$CHECKSUM_TMP" "${EXPORT_FILE}.sha256"
    CHECKSUM_TMP=""
}

main() {
    parse_args "$@"
    configure_release
    if ((!SKIP_IMPORT)); then
        configure_sudo
    fi
    validate_configuration

    if ((!SKIP_SYNC)); then
        sync_sources
    fi
    if ((!SKIP_PATCHES)); then
        apply_redroid_patches
    fi
    if ((!SKIP_BUILD)); then
        if ((RELEASE_BUILD)); then
            prepare_release_password
        fi
        build_android
    fi
    if ((!SKIP_IMPORT)); then
        import_runtime_image
    fi
    if ((!SKIP_EXPORT)); then
        export_runtime_image
    fi

    log "Completed"
    if ((!SKIP_IMPORT || !SKIP_EXPORT)); then
        docker image inspect \
            --format='image={{index .RepoTags 0}} ID={{.Id}} size={{.Size}}' \
            "$RUNTIME_IMAGE"
    fi
    if ((!SKIP_EXPORT)); then
        ls -lh "$EXPORT_FILE" "${EXPORT_FILE}.sha256"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
