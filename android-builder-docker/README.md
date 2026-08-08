# Build Docker

The default configuration uses the upstream AOSP manifest and Debian package
servers. Proxies and mirrors are optional; leave the corresponding variables
unset to use the defaults.

```bash
#####################
# fetch code
#####################
mkdir ~/floral && cd ~/floral

# Optional examples:
# export HTTP_PROXY=http://proxy.example:8080
# export HTTPS_PROXY=http://proxy.example:8080
# export NO_PROXY=localhost,127.0.0.1
# export REPO_URL=https://github.com/aosp-mirror/tools_repo.git
# export AOSP_MANIFEST_URL=https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/manifest

AOSP_MANIFEST_URL=${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}
LOCAL_MANIFEST_URL=${LOCAL_MANIFEST_URL:-https://github.com/FloralDroid/local_manifests.git}

repo init -u "$AOSP_MANIFEST_URL" --git-lfs --depth=1 -b android-12.0.0_r32

# Add the FloralDroid projects. platform_manifests is not used.
git clone "$LOCAL_MANIFEST_URL" ~/floral/.repo/local_manifests -b 12.0.0

# sync code
repo sync -c -j$(nproc)

# Apply the matching FloralDroid patches after every clean source sync.
git clone https://github.com/FloralDroid/redroid-patches.git ~/redroid-patches
~/redroid-patches/apply-patch.sh ~/floral

#####################
# create builder
#####################
# Debian main and security mirrors are independently optional, for example:
# export APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian
# export APT_SECURITY_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian-security
docker build \
    --build-arg userid=$(id -u) \
    --build-arg groupid=$(id -g) \
    --build-arg username=$(id -un) \
    --build-arg APT_MIRROR="${APT_MIRROR:-}" \
    --build-arg APT_SECURITY_MIRROR="${APT_SECURITY_MIRROR:-}" \
    --build-arg HTTP_PROXY="${HTTP_PROXY:-}" \
    --build-arg HTTPS_PROXY="${HTTPS_PROXY:-}" \
    --build-arg NO_PROXY="${NO_PROXY:-}" \
    -t floral-builder .

#####################
# start builder
#####################
docker run -it --rm --hostname floral-builder --name floral-builder -v ~/floral:/src floral-builder

#####################
# build floral
#####################
cd /src

. build/envsetup.sh

lunch redroid_x86_64-userdebug
# redroid_arm64-userdebug
# redroid_x86_64_only-userdebug (64 bit only, redroid 12+)
# redroid_arm64_only-userdebug (64 bit only, redroid 12+)

# start to build
m

#####################
# create floral image in *HOST*
#####################
cd ~/floral/out/target/product/redroid_x86_64

sudo mount system.img system -o ro
sudo mount vendor.img vendor -o ro
sudo tar --xattrs -c vendor -C system --exclude="./vendor" . | docker import -c 'ENTRYPOINT ["/init", "androidboot.hardware=floral"]' - floral:12.0.0
sudo umount system vendor

# create rootfs only image for develop purpose
tar --xattrs -c -C root . | docker import -c 'ENTRYPOINT ["/init", "androidboot.hardware=floral"]' - floral-dev

# Optional: export the finished image for another host.
docker save floral:12.0.0 | gzip -1 > ~/floral-12.0.0.tar.gz
```

`HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` are inherited by `repo`, Git, and
the Docker build only when configured. Proxy credentials are passed as Docker's
predefined proxy build arguments and are not added to the Dockerfile.

When `/src` is mounted, the container automatically registers the ncurses 5
and tinfo 5 libraries from AOSP's bundled host sysroot. This keeps Android 12's
legacy RenderScript clang working on Debian 13 without replacing system libc.

## Build with GApps

You can build a redroid image with your favorite GApps package if you need, for simplicity there is an example with Mind The Gapps.

This is not different from the normal building process, except for some small things, like:

- When following the "Sync Code" paragraph,  after running the repo sync, add this manifest under .repo/local_manifests/mindthegapps.xml, for the specific redroid revision selected.

  For example, for Redroid 11 the revision is 'rho', and for Redroid 12 is 'sigma', and this is the expected manifest:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
          <remote name="mtg" fetch="https://gitlab.com/MindTheGapps/" />
          <project path="vendor/gapps" name="vendor_gapps" revision="sigma" remote="mtg" />
  </manifest>
  ```

- Add the path to the mk file corresponding to your selected arch to `device/redroid/redroid_ARCHITECTURE/device.mk` , for example we want x86_64 arch (x86 for redroid 11 as in 'rho' Mind The Gapps as only x86 GApps)

  ```makefile
  $(call inherit-product, vendor/gapps/x86_64/x86_64-vendor.mk)
  ```

  putting this, modified for the corresponding architecture you need. So change 'x86_64' with arm64 if you need arm64 GApps.

  Resync the repo with a new `repo sync -c` and continue following the building guide exactly as before.

- OPTIONAL but recommended. While importing the image, change the entrypoint to 'ENTRYPOINT ["/init", "androidboot.hardware=floral", "ro.setupwizard.mode=DISABLED"]' , so you avoid doing it manually at every container start, or if you want set `ro.setupwizard.mode=DISABLED` at container start, skipping the GApps setup wizard at redroid boot.
