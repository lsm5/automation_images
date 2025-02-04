#!/bin/bash

# This script is called by packer on the subject fedora VM, to setup the podman
# build/test environment.  It's not intended to be used outside of this context.

set -e

SCRIPT_FILEPATH=$(realpath "$0")
SCRIPT_DIRPATH=$(dirname "$SCRIPT_FILEPATH")
REPO_DIRPATH=$(realpath "$SCRIPT_DIRPATH/../")

# Run as quickly as possible after boot
/bin/bash $REPO_DIRPATH/systemd_banish.sh

# shellcheck source=./lib.sh
source "$REPO_DIRPATH/lib.sh"

# packer and/or a --build-arg define this envar value uniformly
# for both VM and container image build workflows.
req_env_vars PACKER_BUILD_NAME

bash $SCRIPT_DIRPATH/build-push_packaging.sh

# Registers qemu emulation for non-native execution
$SUDO systemctl enable systemd-binfmt

# Pre-populate container storage with multi-arch base images
for arch in amd64 s390x ppc64le arm64; do
    msg "Caching latest $arch fedora image..."
    $SUDO podman pull --quiet --arch=$arch \
        registry.fedoraproject.org/fedora:$OS_RELEASE_VER
done

finalize

echo "SUCCESS!"
