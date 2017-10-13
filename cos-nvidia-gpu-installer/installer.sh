#!/bin/bash

# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is for dynamically installing nvidia kernel drivers in Container Optimized OS

set -o errexit
set -o pipefail
set -u
set -x

# The script must be run as a root.
# Input:
#
# Environment Variables
# BASE_DIR - Directory that is mapped to a stateful partition on host. Defaults to `/rootfs/nvidia`.
# LAKITU_KERNEL_SHA1 (Optional) - If set, it should point to the HEAD of the kernel version used on the host. Otherwise, the script will attempt to auto-detect kernel commit ID from `/etc/os-release`
#
# The script will output the following artifacts:
# ${BASE_DIR}/lib* --> Nvidia CUDA libraries
# ${BASE_DIR}/bin/* --> Nvidia debug utilities
# ${BASE_DIR}/.cache/* --> Nvidia driver artifacts cached for idempotency.
#
# DEVICE_PLUGIN_ENABLED - whether the container is running with device plugin enabled. Defaults to false.

BASE_DIR=${BASE_DIR:-"/rootfs/nvidia"}
CACHE_DIR="${BASE_DIR}/.cache"
USR_WORK_DIR="${CACHE_DIR}/usr-work"
USR_WRITABLE_DIR="${CACHE_DIR}/usr-writable"
LIB_WORK_DIR="${CACHE_DIR}/lib-work"
LIB_WRITABLE_DIR="${CACHE_DIR}/lib-writable"

LIB_OUTPUT_DIR="${BASE_DIR}/lib"
BIN_OUTPUT_DIR="${BASE_DIR}/bin"

KERNEL_SRC_DIR="/lakitu-kernel"

NVIDIA_DRIVER_DIR="/nvidia"
NVIDIA_DRIVER_VERSION="375.51"

# Source: https://www.nvidia.com/Download/index.aspx?lang=en-us
NVIDIA_DRIVER_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
NVIDIA_DRIVER_MD5SUM="beb44468e620f77cbcc25ce33337af01"
NVIDIA_DRIVER_PKG_NAME="NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"

DEVICE_PLUGIN_ENABLED=${DEVICE_PLUGIN_ENABLED:-"false"}

check_nvidia_device() {
    lspci
    if ! lspci | grep -i -q NVIDIA; then
        echo "No NVIDIA devices attached to this instance."
        exit 0
    fi
    echo "Found NVIDIA device on this instance."
}

prepare_kernel_source() {
    # Checkout the correct tag.
    pushd "${KERNEL_SRC_DIR}"
    if ! git checkout ${LAKITU_KERNEL_SHA1}; then
      until git fetch origin
      do
        echo "Fetching origin failed for Lakitu kernel source git repo. Retrying after 5 seconds" && sleep 5
      done
      git checkout ${LAKITU_KERNEL_SHA1}
    fi

    # Prepare kernel configu and source for modules.
    echo "Preparing kernel sources ..."
    zcat "/proc/config.gz" > ".config"
    make olddefconfig
    make modules_prepare
    # Done.
    popd
}

download_install_nvidia() {
    local pkg_name="${NVIDIA_DRIVER_PKG_NAME}"
    local url="${NVIDIA_DRIVER_URL}"
    local log_file_name="${NVIDIA_DRIVER_DIR}/nvidia-installer.log"

    mkdir -p "${NVIDIA_DRIVER_DIR}"
    pushd "${NVIDIA_DRIVER_DIR}"

    echo "Downloading Nvidia driver from ${url} ..."
    curl -L -s -S "${url}" -o "${pkg_name}"
    echo "${NVIDIA_DRIVER_MD5SUM} ${pkg_name}" | md5sum --check

    echo "Running the Nvidia driver installer ..."
    if ! sh "${NVIDIA_DRIVER_PKG_NAME}" --kernel-source-path="${KERNEL_SRC_DIR}" --silent --accept-license --keep --log-file-name="${log_file_name}"; then
        echo "Nvidia installer failed, log below:"
        echo "==================================="
        tail -50 "${log_file_name}"
        echo "==================================="
        exit 1
    fi
    popd
}

unlock_loadpin_and_reboot_if_needed() {
    kernel_cmdline="$(cat /proc/cmdline)"
    if echo "${kernel_cmdline}" | grep -q -v "lsm.module_locking=0"; then
        local -r esp_partition="/dev/sda12"
        local -r mount_path="/tmp/esp"
        local -r grub_cfg="efi/boot/grub.cfg"

        mkdir -p "${mount_path}"
        mount "${esp_partition}" "${mount_path}"

        pushd "${mount_path}"
        cp "${grub_cfg}" "${grub_cfg}.orig"
        sed 's/cros_efi/cros_efi lsm.module_locking=0/g' -i "efi/boot/grub.cfg"
        cat "${grub_cfg}"
        popd
        sync
        umount "${mount_path}"
        # Restart the node for loadpin to be disabled.
        echo b > /sysrq
    fi
}

create_uvm_device() {
    # Create unified memory device file.
    nvidia-modprobe -c0 -u
}

verify_base_image() {
    mount --bind /rootfs/etc/os-release /etc/os-release
    local id="$(grep "^ID=" /etc/os-release)"
    if [[ "${id#*=}" != "cos" ]]; then
        echo "This installer is designed to run on Container-Optimized OS only"
        exit 1
    fi
}

cache_kernel_commit() {
    # Attempt to cache Kernel Commit ID from /etc/os-release if it's not already set.
    if [[ -z ${LAKITU_KERNEL_SHA1+x} ]]; then
        local kernel_sha
        kernel_sha=$(grep "^KERNEL_COMMIT_ID=" /etc/os-release)
        if [[ $? != 0 ]]; then
            echo "Failed to identify kernel commit ID for underlying COS base image from /etc/os-release"
            cat /etc/os-release
            exit 1
        fi
        LAKITU_KERNEL_SHA1=$(echo ${kernel_sha} | cut -d= -f2)
    fi
}

setup_overlay_mounts() {
    mkdir -p ${USR_WRITABLE_DIR} ${USR_WORK_DIR} ${LIB_WRITABLE_DIR} ${LIB_WORK_DIR}
    if ! mount | grep "lowerdir=/usr,upperdir=${USR_WRITABLE_DIR}"; then
        mount -t overlay -o lowerdir=/usr,upperdir=${USR_WRITABLE_DIR},workdir=${USR_WORK_DIR} none /usr
    fi
    if ! mount | grep "lowerdir=/lib,upperdir=${LIB_WRITABLE_DIR}"; then
        mount -t overlay -o lowerdir=/lib,upperdir=${LIB_WRITABLE_DIR},workdir=${LIB_WORK_DIR} none /lib
    fi
}

exit_if_install_not_needed() {
    if nvidia-smi; then
        echo "nvidia drivers already installed. Skipping installation"
        post_installation_sequence
        exit 0
    fi
}

restart_kubelet() {
    if [ "${DEVICE_PLUGIN_ENABLED}" == "true" ]; then
        echo "Device plugin enabled. Skip restarting kubelet"
    else
        echo "Sending SIGTERM to kubelet"
        if pidof kubelet &> /dev/null; then
            pkill -SIGTERM kubelet
        fi
    fi
}

# Copy user space libraries and debug utilities to a special output directory on the host.
# Make these artifacts world readable and executable.
copy_files_to_host() {
    mkdir -p ${LIB_OUTPUT_DIR} ${BIN_OUTPUT_DIR}
    cp -r ${USR_WRITABLE_DIR}/lib/x86_64-linux-gnu/* ${LIB_OUTPUT_DIR}/
    cp -r ${USR_WRITABLE_DIR}/bin/* ${BIN_OUTPUT_DIR}/
    chmod -R a+rx ${LIB_OUTPUT_DIR}
    chmod -R a+rx ${BIN_OUTPUT_DIR}
}

post_installation_sequence() {
    create_uvm_device
    # Copy nvidia user space libraries and debug tools to the host for use from other containers.
    copy_files_to_host
    # Restart the kubelet for it to pick up the GPU devices.
    restart_kubelet
}

main() {
    # Do not run the installer unless the base image is Container Optimized OS (COS)
    verify_base_image
    # Do not run the installer unless a Nvidia device is found on the PCI bus
    check_nvidia_device
    # Identify kernel commit id for the base image. Exits if commit id cannot be identified.
    cache_kernel_commit
    # Setup overlay mounts to capture nvidia driver artificats in a more permanent storage on the host.
    setup_overlay_mounts
    # Disable a critical security feature in COS that will allow for dynamically loading Nvidia drivers
    unlock_loadpin_and_reboot_if_needed
    # Exit if installation is not required (for idempotency)
    exit_if_install_not_needed
    # Checkout kernel sources appropriate for the base image.
    prepare_kernel_source
    # Download, compile and install nvidia drivers.
    download_install_nvidia
    # Verify that the Nvidia drivers have been successfully installed.
    nvidia-smi
    # Perform post installation steps - copying artifacts, restarting kubelet, etc.
    post_installation_sequence
}

main "$@"
