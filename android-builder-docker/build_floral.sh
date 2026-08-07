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

#####################
# State and helpers
#####################

MOUNT_ROOT=""
SYSTEM_MOUNT=""
VENDOR_MOUNT=""
EXPORT_TMP=""
CHECKSUM_TMP=""
PATCH_HISTORY_TMP=""
BUILDER_STARTED=0
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

Synchronize FloralDroid sources, apply only missing ReDroid patches, build
inside the existing floral-builder image, import the runtime image, and export
it as a gzip-compressed Docker archive.

Options:
  --skip-sync                 Do not update manifests, sources, or patch repo
  --skip-patches              Do not verify or apply ReDroid patches
  --skip-build                Reuse existing system.img and vendor.img
  --skip-import               Reuse an existing Docker runtime image
  --skip-export               Do not export the Docker runtime image
  --replace-failed-container  Remove an existing builder container
  --keep-builder-container    Keep the builder container after a successful build
  -h, --help                  Show this help

Configuration is provided through the environment variables declared at the
top of this script. Common overrides include AOSP_DIR, JOBS, LUNCH_TARGET,
BUILDER_IMAGE, RUNTIME_IMAGE, RUNTIME_PLATFORM, BUILD_LOG, and EXPORT_FILE.
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
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

    if ! unmount_images; then
        warn "One or more image mounts require manual cleanup under $MOUNT_ROOT"
    fi

    if [[ -n "$EXPORT_TMP" && -f "$EXPORT_TMP" ]]; then
        rm -f -- "$EXPORT_TMP"
    fi
    if [[ -n "$CHECKSUM_TMP" && -f "$CHECKSUM_TMP" ]]; then
        rm -f -- "$CHECKSUM_TMP"
    fi
    if [[ -n "$PATCH_HISTORY_TMP" && -f "$PATCH_HISTORY_TMP" ]]; then
        rm -f -- "$PATCH_HISTORY_TMP"
    fi

    if ((rc != 0 && BUILDER_STARTED)) && container_exists; then
        warn "Builder container preserved for diagnosis: $BUILDER_CONTAINER"
        printf '  docker logs %q\n' "$BUILDER_CONTAINER" >&2
        printf '  docker exec -it %q /bin/bash\n' "$BUILDER_CONTAINER" >&2
        printf '  build log: %s\n' "$BUILD_LOG" >&2
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

validate_configuration() {
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
    [[ "$PATCH_HISTORY_DEPTH" =~ ^[1-9][0-9]*$ ]] ||
        die "PATCH_HISTORY_DEPTH must be a positive integer"
    [[ "$PRODUCT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid PRODUCT_NAME"
    [[ "$LUNCH_TARGET" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid LUNCH_TARGET"
    [[ "$BUILDER_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] ||
        die "Invalid BUILDER_CONTAINER"

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

ensure_no_tracked_changes() {
    local repo_dir=$1
    local label=$2
    local status

    status=$(git -C "$repo_dir" status --porcelain --untracked-files=no)
    [[ -z "$status" ]] || die "$label contains tracked local changes: $repo_dir"
}

update_checkout() {
    local directory=$1
    local url=$2
    local branch=$3
    local label=$4

    if [[ -d "$directory/.git" ]]; then
        ensure_no_tracked_changes "$directory" "$label"
        run git -C "$directory" fetch --prune origin "$branch"

        if git -C "$directory" show-ref --verify --quiet "refs/heads/$branch"; then
            run git -C "$directory" checkout "$branch"
        else
            run git -C "$directory" checkout --track -b "$branch" "origin/$branch"
        fi
        run git -C "$directory" merge --ff-only "origin/$branch"
    elif [[ -e "$directory" ]]; then
        die "$directory exists but is not a Git repository"
    else
        run git clone --branch "$branch" --single-branch "$url" "$directory"
    fi
}

sync_sources() {
    log "Update FloralDroid local manifests"
    update_checkout "$LOCAL_MANIFEST_DIR" "$LOCAL_MANIFEST_URL" \
        "$LOCAL_MANIFEST_BRANCH" "Local manifest repository"

    log "Sync AOSP and FloralDroid sources (jobs=$JOBS)"
    (
        cd "$AOSP_DIR"
        run "${REPO[@]}" sync -c -j"$JOBS"
    )

    log "Update ReDroid patch repository"
    update_checkout "$PATCH_DIR" "$PATCH_URL" "$PATCH_BRANCH" "Patch repository"
}

#####################
# Incremental patch application
#####################

detect_aosp_tag() {
    local revision
    revision=$(xmllint --xpath 'string(/manifest/default/@revision)' \
        "$AOSP_DIR/.repo/manifests/default.xml")
    [[ -n "$revision" ]] || die "Cannot detect AOSP revision from the manifest"
    printf '%s\n' "${revision##*/}"
}

stable_patch_id() {
    local patch=$1
    git patch-id --stable <"$patch" | awk 'NR == 1 { print $1 }'
}

ensure_patch_repo_clean() {
    local repo_dir=$1
    local project=$2
    local git_dir
    local status

    git_dir=$(git -C "$repo_dir" rev-parse --absolute-git-dir)
    [[ ! -d "$git_dir/rebase-apply" && ! -d "$git_dir/rebase-merge" ]] ||
        die "Unfinished Git operation in $project: $repo_dir"

    status=$(git -C "$repo_dir" status --porcelain --untracked-files=no)
    [[ -z "$status" ]] || die "Tracked local changes in patched project $project"
}

apply_missing_patches() {
    local tag=${1:-$(detect_aosp_tag)}
    local patch_root="$PATCH_DIR/$tag"
    local patch_directory
    local project
    local source_repo
    local history_file
    local patch
    local patch_id
    local applied_commit
    local applied=0
    local skipped=0

    [[ -d "$patch_root" ]] || die "Patch directory does not exist: $patch_root"

    log "Apply missing ReDroid patches for $tag"

    while IFS= read -r patch_directory; do
        project=${patch_directory#"$patch_root"/}
        source_repo="$AOSP_DIR/$project"
        [[ -d "$source_repo/.git" ]] || die "Source repository not found: $source_repo"

        ensure_patch_repo_clean "$source_repo" "$project"
        PATCH_HISTORY_TMP=$(mktemp /tmp/floral-patch-history.XXXXXX)
        history_file=$PATCH_HISTORY_TMP

        if ! git -C "$source_repo" log -p --no-merges \
            --max-count="$PATCH_HISTORY_DEPTH" --format='commit %H' |
            git patch-id --stable >"$history_file"; then
            rm -f -- "$history_file"
            PATCH_HISTORY_TMP=""
            die "Cannot calculate patch history for $project"
        fi

        printf '\nproject: %s\n' "$project"
        while IFS= read -r patch; do
            if ! patch_id=$(stable_patch_id "$patch") || [[ -z "$patch_id" ]]; then
                rm -f -- "$history_file"
                PATCH_HISTORY_TMP=""
                die "Cannot calculate patch ID: $patch"
            fi

            applied_commit=$(awk -v expected="$patch_id" \
                '$1 == expected { print $2; exit }' "$history_file")
            if [[ -n "$applied_commit" ]]; then
                printf 'skip:  %s (commit=%s)\n' "$(basename "$patch")" "$applied_commit"
                ((skipped += 1))
                continue
            fi

            printf 'apply: %s\n' "$(basename "$patch")"
            if ! git -C "$source_repo" am --reject "$patch"; then
                rm -f -- "$history_file"
                PATCH_HISTORY_TMP=""
                die "Patch failed in $project; Git am state was preserved for diagnosis"
            fi
            printf '%s %s\n' "$patch_id" "$(git -C "$source_repo" rev-parse HEAD)" \
                >>"$history_file"
            ((applied += 1))
        done < <(find "$patch_directory" -maxdepth 1 -type f -name '*.patch' | sort)

        rm -f -- "$history_file"
        PATCH_HISTORY_TMP=""
    done < <(find "$patch_root" -type f -name '*.patch' -printf '%h\n' | sort -u)

    log "Patch state ready: applied=$applied skipped=$skipped"
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

build_android() {
    local builder_user
    local passwd_entry
    local builder_home
    local lunch_target_q
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

    printf -v lunch_target_q '%q' "$LUNCH_TARGET"
    build_script="set -Eeuo pipefail
source build/envsetup.sh
lunch $lunch_target_q
m -j$JOBS"

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
        die "Android build failed; builder container was preserved"
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
}

#####################
# Runtime image import
#####################

mount_images() {
    local system_image="$PRODUCT_DIR/system.img"
    local vendor_image="$PRODUCT_DIR/vendor.img"

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
    if ((!SKIP_IMPORT)); then
        configure_sudo
    fi
    validate_configuration

    if ((!SKIP_SYNC)); then
        sync_sources
    fi
    if ((!SKIP_PATCHES)); then
        apply_missing_patches
    fi
    if ((!SKIP_BUILD)); then
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
