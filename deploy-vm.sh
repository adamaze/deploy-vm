#!/bin/bash
#
# https://github.com/adamaze/deploy-vm
#
# Vars
var_file=~/.config/deploy-vm/default.vars
supported_os_list="
centos-stream9
centos-stream10
rocky8
rocky9
almalinux8
almalinux9
opensuse15-6
debian11
debian12
debiansid
fedora40
fedora41
fedora42
ubuntu2204
ubuntu2404
ubuntu2410
ubuntu2504
"
# currently unsupported:
# arch
#
# FUNCTIONS
#
ask() {
    local prompt default reply

    if [[ ${2:-} = 'Y' ]]; then
        prompt='Y/n'
        default='Y'
    elif [[ ${2:-} = 'N' ]]; then
        prompt='y/N'
        default='N'
    else
        prompt='y/n'
        default=''
    fi

    while true; do

        # Ask the question (not using "read -p" as it uses stderr not stdout)
        echo -n "$1 [$prompt] "

        # Read the answer (use /dev/tty in case stdin is redirected from somewhere else)
        read -r reply </dev/tty

        # Default?
        if [[ -z $reply ]]; then
            reply=$default
        fi

        # Check if the reply is valid
        case "$reply" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac

    done
}
#
function usage() {
    echo "Usage: $0 -h hostname_to_build | [-c cpu_core_count] [-r ram_in_GB] [-d disk_size] [-o os]" 1>&2
    echo "  -l   List avilable OS versions." 1>&2
    echo "  -F   Skip the y/n prompt when deploying." 1>&2
    exit 1
 }
#
function set_defaults() {
    mkdir -p $(dirname $var_file)
    echo "Creating var file: $var_file"
    echo "# settings for deploy-vm script
VM_IMAGE_DIR=/var/lib/libvirt
user=adam
ram=2048
cpu=2
disk_size=20
os=rocky9
ssh_pub_key_file=
BRIDGE=br0
github_user=
runcmd=
user_data_file=
" > $var_file
}
function load_settings() {
    . $var_file
    mkdir -p "$VM_IMAGE_DIR"/{images,init,base}
    # validate SSH keys
    if [[ ! -e $ssh_pub_key_file ]] && [[ -z $github_user ]]; then
    	echo "ssh_pub_key_file: $ssh_pub_key_file does not exist, and \$github_user is not set"
    	exit 1
    fi
    if [[ -n $github_user ]]; then
        github_ssh_keys=$(curl --silent https://github.com/${github_user}.keys )
        if [[ $? -ne 0 ]] || [[ -z $github_ssh_keys ]]; then
            echo "Unable to grab ssh keys from github user $github_user"
            exit 1
        fi
    fi
    if [[ -n $user_data_file ]] && [[ ! -e $user_data_file ]]; then
        echo "Specified user_data_file does not exist: $user_data_file"
        exit 1
    fi
}
function generate_server_name() {
  wordlist="/usr/share/dict/words"

  # Check if wordlist exists
  if [[ ! -f "$wordlist" ]]; then
    echo "wordlist not found. You may need to install a package, or specify a hostname with -h" >&2
    echo "sudo dnf install words  # For Red Hat/Rocky/Alma Linux" >&2
    echo "sudo apt install wamerican  # For Debian/Ubuntu" >&2
    exit 1
  fi

  # Filter for appropriate words (4-8 chars, alphabetic only)
  hostname_word_1=$(grep -E '^[a-z]{4,8}$' "$wordlist" | shuf -n 1)
  hostname_word_2=$(grep -E '^[a-z]{4,8}$' "$wordlist" | shuf -n 1)

  hostname_to_build="${os}-${hostname_word_1}-${hostname_word_2}"
}

function validate_input() {
    # check if name is valid
    if [[ ! "$hostname_to_build" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo "ERROR: hostname can only contain [a-zA-Z0-9-]"
        ((validation_errors++))
    fi
    # check if name pings
    if [[ $(ping -c1 -W1 $hostname_to_build >/dev/null 2>&1; echo $?) -eq 0 ]]; then
        echo "ERROR: $hostname_to_build already responds to ping."
        ((validation_errors++))
    fi
    # check if vm exists with name
    if [[ $(virsh list --name | grep -i ^${hostname_to_build}$ >/dev/null 2>&1; echo $?) -eq 0 ]]; then
        echo "ERROR: $hostname_to_build already exists."
        ((validation_errors++))
    fi
    # check if enough CPU cores exist
    if [[ $cpu -gt $(nproc) ]]; then
        echo "ERROR: You asked for $cpu cores, but this system only has $(nproc)."
        ((validation_errors++))
    fi
    # check if enough RAM exists
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_mem_mb=$((total_mem_kb / 1024))
    if [[ $ram -gt $total_mem_mb ]]; then
        echo "ERROR: You asked for $ram MB of ram, but this sytem only has ${total_mem_mb}MB."
        ((validation_errors++))
    fi
    # check if enough disk space exists
    available_space=$(df -BG $VM_IMAGE_DIR --output=avail| tail -1 | sed 's/G//' | awk '{print $1}' )
    if [[ $disk_size -gt $available_space ]]; then
        echo "ERROR: You asked for a ${disk_size}GB disk, but $VM_IMAGE_DIR only has ${available_space}GB "
        ((validation_errors++))
    fi
    if [[ $validation_errors -gt 0 ]]; then
        echo "Validation errors found. exiting..."
        exit 1
    fi
}
function cache_image() {
    mkdir -p $VM_IMAGE_DIR/base
    checksum_type=sha256
    case "$os" in
        centos-stream9)
            OS_VARIANT="centos-stream9"
            IMAGE_URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2.SHA256SUM | tail -1 | awk '{print $NF}')"
            ;;
        centos-stream10)
            OS_VARIANT="centos-stream9"
            IMAGE_URL="https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2.SHA256SUM | tail -1 | awk '{print $NF}')"
            ;;
        rocky8)
            OS_VARIANT="rocky8"
            IMAGE_URL="https://dl.rockylinux.org/vault/rocky/8.9/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://dl.rockylinux.org/vault/rocky/8.9/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2.CHECKSUM | tail -1 | awk '{print $NF}')"
            ;;
        rocky9)
            OS_VARIANT="rocky9"
            IMAGE_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2.CHECKSUM | tail -1 | awk '{print $NF}')"
            ;;
        almalinux8)
            OS_VARIANT="almalinux8"
            IMAGE_URL="https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/CHECKSUM | grep $(basename $IMAGE_URL) | awk '{print $1}')"
            ;;
        almalinux9)
            OS_VARIANT="almalinux9"
            IMAGE_URL="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM | grep $(basename $IMAGE_URL) | awk '{print $1}')"
            ;;
        opensuse15-6)
            OS_VARIANT="$(osinfo-query os | grep opensuse15.6 | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep opensuse15 | sort -n -t\| -k3 -r | head -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://mirror.rackspace.com/openSUSE/distribution/leap/15.6/appliances/openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://mirror.rackspace.com/openSUSE/distribution/leap/15.6/appliances/openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2.sha256 | grep $(basename $IMAGE_URL) | awk '{print $1}')"
            ;;
        # we use the "generic" image for debian, as the "genericcloud" one doesnt have drivers for the cdrom drive cloud-init uses
        # https://salsa.debian.org/kernel-team/linux/-/merge_requests/699
        debian11)
            OS_VARIANT="debian11"
            IMAGE_URL="http://cdimage.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent http://cdimage.debian.org/images/cloud/bullseye/latest/SHA512SUMS | grep $(basename $IMAGE_URL) | awk '{print $1}')"
            checksum_type=sha512
            ;;
        debian12)
            OS_VARIANT="debian12"
            IMAGE_URL="http://cdimage.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent http://cdimage.debian.org/images/cloud/bookworm/latest/SHA512SUMS | grep $(basename $IMAGE_URL) | awk '{print $1}')"
            checksum_type=sha512
            ;;
        debiansid)
            OS_VARIANT="debiantesting"
            IMAGE_URL="http://cdimage.debian.org/images/cloud/sid/daily/latest/debian-sid-generic-amd64-daily.qcow2"
            IMAGE_CHECKSUM="$(curl --silent http://cdimage.debian.org/images/cloud/sid/daily/latest/SHA512SUMS | grep $(basename $IMAGE_URL) | awk '{print $1}')"
            checksum_type=sha512
            ;;
        # for fedora and ubuntu, try to use the exact os name, but if that isnt there, just use the latest osinfo-query knows about
        fedora40)
            OS_VARIANT="$(osinfo-query os | grep '^ fedora40' | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep ' Fedora Linux ' | sort -n -t\| -k3 | tail -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://fedora.mirror.constant.com/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://fedora.mirror.constant.com/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-40-1.14-x86_64-CHECKSUM | grep $(basename $IMAGE_URL) | grep SHA256 | awk '{print $NF}')"
            ;;
        fedora41)
            OS_VARIANT="$(osinfo-query os | grep '^ fedora41' | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep ' Fedora Linux ' | sort -n -t\| -k3 | tail -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://fedora.mirror.constant.com/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://fedora.mirror.constant.com/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-41-1.4-x86_64-CHECKSUM | grep $(basename $IMAGE_URL) | grep SHA256 | awk '{print $NF}')"
            ;;
        fedora42)
            OS_VARIANT="$(osinfo-query os | grep '^ fedora42' | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep ' Fedora Linux ' | sort -n -t\| -k3 | tail -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://fedora.mirror.constant.com/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
            IMAGE_CHECKSUM="$(curl --silent https://fedora.mirror.constant.com/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-42-1.1-x86_64-CHECKSUM | grep $(basename $IMAGE_URL) | grep SHA256 | awk '{print $NF}')"
            ;;
        ubuntu2204)
            OS_VARIANT="$(osinfo-query os | grep '^ ubuntu22.04' | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep '^ ubuntu' | sort -n -t\| -k3 | tail -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img"
            IMAGE_CHECKSUM="$(curl --silent https://cloud-images.ubuntu.com/releases/jammy/release/SHA256SUMS | grep $(basename $IMAGE_URL)| awk '{print $1}')"
            ;;
        ubuntu2404)
            OS_VARIANT="$(osinfo-query os | grep ' ^ubuntu24.04' | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep '^ ubuntu' | sort -n -t\| -k3 | tail -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
            IMAGE_CHECKSUM="$(curl --silent https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS | grep $(basename $IMAGE_URL)| awk '{print $1}')"
            ;;
        ubuntu2410)
            OS_VARIANT="$(osinfo-query os | grep '^ ubuntu24.10' | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep '^ ubuntu' | sort -n -t\| -k3 | tail -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://cloud-images.ubuntu.com/releases/oracular/release/ubuntu-24.10-server-cloudimg-amd64.img"
            IMAGE_CHECKSUM="$(curl --silent https://cloud-images.ubuntu.com/releases/oracular/release/SHA256SUMS | grep $(basename $IMAGE_URL)| awk '{print $1}')"
            ;;
        ubuntu2504)
            OS_VARIANT="$(osinfo-query os | grep '^ ubuntu25.04' | awk '{print $1}')"
            if [[ -z $OS_VARIANT ]]; then
                OS_VARIANT="$(osinfo-query os | grep '^ ubuntu' | sort -n -t\| -k3 | tail -1 | awk '{print $1}')"
            fi
            IMAGE_URL="https://cloud-images.ubuntu.com/releases/plucky/release/ubuntu-25.04-server-cloudimg-amd64.img"
            IMAGE_CHECKSUM="$(curl --silent https://cloud-images.ubuntu.com/releases/plucky/release/SHA256SUMS | grep $(basename $IMAGE_URL)| awk '{print $1}')"
            ;;
        #arch)
        #    OS_VARIANT="archlinux"
        #    IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
        #    IMAGE_CHECKSUM="$(curl --silent https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256 | awk '{print $1}')"
        #    ;;
        *)
            echo See supported OS list:
            echo "$supported_os_list"
            exit 1
            ;;
    esac
    downloaded_base_image=$VM_IMAGE_DIR/base/$os/${IMAGE_CHECKSUM}.qcow2
    mkdir -p $(dirname $downloaded_base_image)
    if [[ ! -e  $downloaded_base_image ]]; then
        echo Downloading latest base image...
        wget --quiet --show-progress -O $downloaded_base_image $IMAGE_URL
        if [[ $? -ne 0 ]]; then
            echo "Failed to download $IMAGE_URL"
            exit 1
        else
            if [[ $(${checksum_type}sum $downloaded_base_image | awk '{print $1}') != "$IMAGE_CHECKSUM" ]]; then
                echo "Download completed, but checksum failed. deleting failed image..."
                rm -f $downloaded_base_image
                exit 1
            fi
        fi 
    else
        if [[ $(${checksum_type}sum $downloaded_base_image | awk '{print $1}') != "$IMAGE_CHECKSUM" ]]; then
            echo "Existing image doesnt match checksum, attempting to complete the download..."
            wget --quiet --show-progress --continue -O $downloaded_base_image $IMAGE_URL
            if [[ $? -ne 0 ]]; then
                echo "Failed to download $IMAGE_URL"
                exit 1
            fi 
        else
            echo "Already have the latest image for $os downloaded"
        fi
    fi
}
function create_disk() {
    vm_image_file=${VM_IMAGE_DIR}/images/${hostname_to_build}.qcow2
    if [[ ! -e $vm_image_file ]]; then 
        echo "Creating a qcow2 image file $vm_image_file that uses the latest cloud image $(basename ${IMAGE_URL}) as its base"
        qemu-img create -b "${downloaded_base_image}" -f qcow2 -F qcow2 "${VM_IMAGE_DIR}/images/${hostname_to_build}.qcow2" "${disk_size}G"
    else
        echo "Image file already exists $vm_image_file"
        exit 1
    fi
}

function create_cloud_init_iso() {
    echo "Creating meta-data file $VM_IMAGE_DIR/init/meta-data"
    cat > "$VM_IMAGE_DIR/init/meta-data" << EOF
instance-id: ${hostname_to_build}
local-hostname: ${hostname_to_build}
EOF

    echo "Creating user-data file $VM_IMAGE_DIR/init/user-data"
    cat > "$VM_IMAGE_DIR/init/user-data" << EOF
#cloud-config

users:
  - name: $user
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: sudo
    shell: /bin/bash
    homedir: /home/$user
    ssh_authorized_keys:
EOF

    if [[ -n $ssh_pub_key_file ]]; then
        echo "Adding keys from the public key file $ssh_pub_key_file to the user-data file"
        while IFS= read -r key; do
            echo "      - $key" >> "$VM_IMAGE_DIR/init/user-data"
        done < <(grep -v '^ *#' < "$ssh_pub_key_file")
    fi
    if [[ -n $github_ssh_keys ]]; then
        echo "Adding keys from https://github.com/${github_user}.keys to the user-data file"
        while IFS= read -r line; do
            echo "      - $line" >> "$VM_IMAGE_DIR/init/user-data"
        done <<< "$github_ssh_keys"
    fi
    if [[ -n $user_data_file ]]; then
        echo "Adding contents of $user_data_file to runcmd list"
        echo "runcmd:" >> $VM_IMAGE_DIR/init/user-data
        cat $user_data_file | sed 's/^/ - /' >> $VM_IMAGE_DIR/init/user-data
    fi

    echo "Generating the cidata ISO file $VM_IMAGE_DIR/images/${hostname_to_build}-cidata.iso"
    (
        cd "$VM_IMAGE_DIR/init/"
        genisoimage_output=$(genisoimage \
            -output "$VM_IMAGE_DIR/images/${hostname_to_build}-cidata.img" \
            -volid cidata \
            -rational-rock \
            -joliet \
            user-data meta-data 2>&1)
    )
}
#
function virt_install() {
    echo Running virt-install
    virt-install \
        --name="${hostname_to_build}" \
        --network "bridge=${BRIDGE},model=virtio" \
        --import \
        --disk "path=$vm_image_file,format=qcow2" \
        --disk "path=$VM_IMAGE_DIR/images/${hostname_to_build}-cidata.img,device=cdrom" \
        --ram="${ram}" \
        --vcpus="${cpu}" \
        --autostart \
        --hvm \
        --arch x86_64 \
        --accelerate \
        --check-cpu \
        --os-variant $OS_VARIANT \
        --force \
        --watchdog=default \
        --graphics vnc,listen=0.0.0.0 \
        --noautoconsole \
        --wait 0
}
#
if [[ ! -e $var_file ]]; then
    # if no var file exists, create it with the defaults
    set_defaults
fi
#
################################################
load_settings
#
while getopts ":h:c:r:d:o:yl" o; do
    case "${o}" in
        h)
            hostname_to_build=${OPTARG}
            ;;
        c)
            cpu=${OPTARG}
            ;;
        r)
            ram=$((${OPTARG}*1024))
            ;;
        d)
            disk_size=${OPTARG}
            ;;
        o)
            os=${OPTARG}
            ;;
        y)
            force=true
            ;;
		l)
			list=true
			;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))
#
if [[ $list == "true" ]]; then
    echo "$supported_os_list"
    exit
fi
#
if [[ -z "${hostname_to_build}" ]]; then
    usage
fi
if [[ "${os}" == "random" ]]; then
    os=$(echo "$supported_os_list" | grep . | sort -R | head -1)
fi
if [[ "${hostname_to_build}" == "random" ]]; then
    generate_server_name
fi
#
if [[ $force != "true" ]]; then
    if ! ask "Are you sure you want to deply the following VM:
    username: $user
    hostname: $hostname_to_build
    os: $os
    CPU cores: $cpu
    RAM (in GB): $(($ram/1024))
    disk size: $disk_size
    "; then
        exit 2
    fi
fi
#
validate_input
cache_image
create_disk
create_cloud_init_iso
virt_install
echo Finished building $hostname_to_build
