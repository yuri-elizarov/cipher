#!/bin/bash -e

COMMAND=$1
PACKAGE=$2
if [ ! -z "${PACKAGE}" ]; then
    FILE="${PACKAGE}.tar.gz"
fi

ENCRYPTED=~/encrypted
DECRYPTED=~/decrypted
SIZE=2048

usage ()
{
    echo "Usage:" >&2
    echo "$0 <command> [package]" >&2
    echo "Where <command> is one of:" >&2
    echo "  encrypt <package>" >&2
    echo "  decrypt <package>" >&2
    echo "  mount" >&2
    echo "  umount" >&2
}


is_mounted ()
{
    mount_point=${1}
    case "$OSTYPE" in
        "darwin*")
            echo $(df "${mount_point}" 2>/dev/null | tail -1 | grep "${mount_point}" | awk '{ print $9 }')
            ;;
        "linux-gnu")
            test -d /dev/shm/"${mount_point}" && echo "mounted"
            ;;
    esac
}

mountfs_mac () 
{
    mount_point=${1}
    size=${2:-64}
    mkdir -p "$mount_point"
    if [ $? -ne 0 ]; then
        echo "Mount point $mount_point is not available." >&2
        exit $?
    fi

    sector=$(expr $size \* 1024 \* 1024 / 512)
    device_name=$(hdid -nomount "ram://${sector}" | awk '{print $1}')
    if [ $? -ne 0 ]; then
        echo "Could not create disk image." >&2
        exit $?
    fi

    newfs_hfs $device_name > /dev/null
    if [ $? -ne 0 ]; then
        echo "Could not format disk image." >&2
        exit $?
    fi

    mount -t hfs $device_name "$mount_point"
    if [ $? -ne 0 ]; then
        echo "Could not mount disk image." >&2
        exit $?
    fi
}

mountfs_linux () 
{
    mount_point=${1}
    size=${2:-64}

    if [[ -e "$mount_point" ]]; then
        echo "Mount point target $mount_point is present, unable to proceed." >&2
        exit 1
    fi

    if [[ -d /dev/shm/"$mount_point" ]]; then
        echo "Directory "$mount_point" on /dev/shm is present, unable to proceed." >&2
        exit 1
    fi

    location=/dev/shm/"${mount_point}"
    mkdir -p $location
    chown $(id -un):$(id -gn) $location
    chmod 0700 $location
    ln -s $location ${mount_point}
}


mountfs() {
    mount_point=${1}
    if [ ! -z $(is_mounted ${mount_point}) ]; then
        echo "$mount_point already mounted." >&2
        exit 0
    fi
    size=${2}
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mountfs_mac "${mount_point}" $size
    elif [[ "$OSTYPE" == "linux-gnu" ]]; then
        mountfs_linux "${mount_point}" $size
    else
        echo "Unknown OS." >&2
        exit 1
    fi
}

decrypt() {
    if [ -z "${PACKAGE}" ]; then
        echo "Missing package name." >&2
        usage
        exit 1
    fi
    if [ -z $(is_mounted ${DECRYPTED}) ]; then
        echo "${DECRYPTED} not mounted."
        exit 1
    fi
    file_name=${ENCRYPTED%%/}/${FILE}.gpg
    gpg --decrypt "${file_name}" | tar -x -z -C "${DECRYPTED}"
}

umountfs_mac ()
{
    mount_point=${1}
    if [ ! -d "${mount_point}" ]; then
        echo "The mount point is not available." >&2
        exit 1
    fi
    mount_point=$(cd $mount_point && pwd)

    device_name=$(df "${mount_point}" 2>/dev/null | tail -1 | grep "${mount_point}" | cut -d' ' -f1)
    if [ -z "${device_name}" ]; then
        echo "Disk image is not mounted." >&2
        exit 1
    fi

    umount "${mount_point}"
    if [ $? -ne 0 ]; then
        echo "Could not unmount." >&2
        exit $?
    fi

    hdiutil detach -quiet $device_name
}

umountfs_linux ()
{
    mount_point=${1}
    if [[ ! -L "${mount_point}" ]]; then
        echo "The mount point is not a symlink to ram location, unable to proceed." >&2
        exit 1
    fi
    if [[ ! -d "${mount_point}" ]]; then
        echo "The mount point does not link to directory." 2>&1
        exit 1
    fi

    location=$(readlink -e $mount_point)

    rm -f "${mount_point}"
    find "$location" -type f -exec shred -z {} \;
    rm -rf "$location"
}

umountfs() {
    mount_point=${1}
    if [[ "$OSTYPE" == "darwin"* ]]; then
        umountfs_mac "${mount_point}"
    elif [[ "$OSTYPE" == "linux-gnu" ]]; then
        umountfs_linux "${mount_point}"
    else
        echo "Unknown OS." >&2
        exit 1
    fi
}

encrypt() {
    file_name=${DECRYPTED%%/}/${PACKAGE}
    output1=${ENCRYPTED%%/}/${PACKAGE}.tar.gz.gpg
    output2=${ENCRYPTED%%/}/${PACKAGE}.tar.gz.enc
    mkdir -p ${ENCRYPTED}
    if [ -f ${output1} ]; then
        read -p "Overwrite existing ${output1}? [Y/N]: " -n 1 -r
        echo
        if ! [[ $REPLY =~ ^[Y]$ ]]; then
            exit 0
        fi
    fi
    tar -c -z -C ${DECRYPTED} "${PACKAGE}" | gpg --cipher-algo AES256 --symmetric > "${output1}"
    tar -c -z -C ${DECRYPTED} "${PACKAGE}" | openssl enc -aes-256-cbc -salt -out "${output2}"
}

case "$COMMAND" in
    encrypt)
        encrypt
        ;;
    umount)
        read -p "This is a potentially DANGEROUS operation, you may loose your unsaved data. Are you sure? [Y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Y]$ ]]; then
            umountfs "${DECRYPTED}"
        fi
        ;;
    decrypt)
        decrypt
        ;;
    mount)
        mountfs "${DECRYPTED}" ${SIZE}
        ;;
    help)
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage
        exit 2
        ;;
esac
