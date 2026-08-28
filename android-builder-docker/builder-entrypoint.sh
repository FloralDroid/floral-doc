#!/bin/bash

set -e

# Android 12 still invokes an old RenderScript clang linked against ncurses 5.
# Debian 13 no longer packages that ABI, but the AOSP host sysroot contains the
# matching libraries. Register only those compatibility libraries so the old
# sysroot cannot override Debian's libc or other host libraries.
configure_aosp_host_compat() {
    local source_dir="/src/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot/usr/lib"
    local compat_dir="/usr/local/lib/aosp-host-compat"

    if [[ ! -f "${source_dir}/libncurses.so.5.9" ||
          ! -f "${source_dir}/libtinfo.so.5.9" ]]; then
        return
    fi

    install -d -m 0755 "${compat_dir}"
    ln -sfn "${source_dir}/libncurses.so.5.9" "${compat_dir}/libncurses.so.5.9"
    ln -sfn "libncurses.so.5.9" "${compat_dir}/libncurses.so.5"
    ln -sfn "${source_dir}/libtinfo.so.5.9" "${compat_dir}/libtinfo.so.5.9"
    ln -sfn "libtinfo.so.5.9" "${compat_dir}/libtinfo.so.5"
    printf '%s\n' "${compat_dir}" > /etc/ld.so.conf.d/aosp-host-compat.conf
    ldconfig
}

configure_aosp_host_compat

builder_user=$(cat /root/builder-user)
export USER="${builder_user}"
export HOME
HOME=$(getent passwd "${builder_user}" | cut -d: -f6)

if (($#)); then
    exec chroot --userspec="${builder_user}" / "$@"
fi

exec chroot --userspec="${builder_user}" / /bin/bash -i
