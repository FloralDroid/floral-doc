FROM debian:13

ARG userid=1000
ARG groupid=1000
ARG username=builder
ARG APT_MIRROR
ARG APT_SECURITY_MIRROR

ENV DEBIAN_FRONTEND=noninteractive

# Mirrors are optional. Debian 13 uses deb822 sources, so main and security
# repositories are replaced independently and retain their original defaults
# when the corresponding argument is empty.
RUN if [ -n "${APT_MIRROR}" ]; then \
        mirror="${APT_MIRROR%/}"; \
        sed -i "s|^URIs: http://deb.debian.org/debian$|URIs: ${mirror}|" \
            /etc/apt/sources.list.d/debian.sources; \
    fi \
    && if [ -n "${APT_SECURITY_MIRROR}" ]; then \
        security_mirror="${APT_SECURITY_MIRROR%/}"; \
        sed -i "s|^URIs: http://deb.debian.org/debian-security$|URIs: ${security_mirror}|" \
            /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get update \
    && echo "install package for building AOSP" \
    && apt-get install -y git-core gnupg flex bison build-essential zip curl zlib1g-dev \
        gcc-multilib g++-multilib libc6-dev-i386 libncurses-dev x11proto-dev \
        libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig \
    && echo "install utils" \
    && apt-get install -y sudo rsync procps \
    && echo "install packages for build mesa3d or meson related" \
    && apt-get install -y python3 python-is-python3 python3-mako meson pkg-config python3-dev ninja-build gettext llvm-17 \
    && python -c 'import mako.template' \
    && rm -rf /var/lib/apt/lists/*

# A root host commonly invokes Docker in CI. Reuse the container root account
# for uid 0; otherwise create a matching user for writable bind-mounted output.
RUN if [ "$userid" = "0" ]; then \
        echo root > /root/builder-user; \
    else \
        groupadd -g "$groupid" "$username" \
        && useradd -m -u "$userid" -g "$groupid" "$username" \
        && echo "$username ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
        && echo "$username:$username" | chpasswd \
        && adduser "$username" sudo \
        && echo "$username" > /root/builder-user; \
    fi

ENV USER=$username \
    PATH=/src/.repo/repo:/src/prebuilts/jdk/jdk8/linux-x86/bin/:$PATH

COPY builder-entrypoint.sh /usr/local/sbin/floral-builder-entrypoint

# The entrypoint registers AOSP's ncurses 5 compatibility libraries before it
# drops privileges and opens the interactive builder shell.
ENTRYPOINT ["/bin/bash", "/usr/local/sbin/floral-builder-entrypoint"]
