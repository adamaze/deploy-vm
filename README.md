# deploy-vm (libvirt/KVM)

![Workflow Status](https://github.com/adamaze/deploy-vm/actions/workflows/cloud_image_health_check.yml/badge.svg)  
tl;dr:  
`./deploy-vm.sh -h server01 -o rocky9`  
Deploy a rocky9 VM named server01 from the lastest cloud image, and include your ssh key for easy access

## Explanation
There are many ways to deploy VMs with libvirt/KVM, but I wanted something super simple that I could wrap my head around, keep up to date easily, and I wanted it to be fast.  
For example, when the image is already cached, deploying centos-stream10 takes 8 seconds, and the vm is up on the network running user-data 42 seconds later.  
When validating all distros, I can deploy one after the other and be done with the 18 currently supported versions in under 5 minutes.

### WARNING
I don't use this script professionally, so I may be doing some things here in a non-ideal way... it happens to be working for me, so I'm running with it. If you think you can point out something I'm doing wrong, with an easy fix, or explanation, I'm all ears in the Issues tab

## Supported OS for KVM host
| Distribution | Versions |
|--------------|----------|
| AlmaLinux | 8, 9 |  
| CentOS Stream | 9, 10 |  
| Fedora | 41, 42 |  
| Rocky Linux | 8, 9 |  

It will likely work on more, this is just what I have validated so far.  

## Supported OS Versions
| Distribution | Versions |
|--------------|----------|
| CentOS Stream | 9, 10 |
| Rocky Linux | 8, 9, 10 |
| AlmaLinux | 8, 9, 10 |
| openSUSE Leap | 15.6 |
| Debian | 11, 12, 13, sid |
| Fedora | 41, 42, 43 |
| Ubuntu | 22.04, 24.04, 24.10, 25.04, 25.10 |  

[This Github Action](https://github.com/adamaze/deploy-vm/actions/workflows/cloud_image_health_check.yml) checks each image URL daily, and auto-creates an issue to report bad links, as distros occasionally change paths of where images are hosted.
## Usage

### Basic
```bash
./deploy-vm.sh -h my-new-vm
```

This will create a VM named "my-new-vm" using the default settings specified in `~/.config/deploy-vm/default.vars`.

### Advanced
```bash
./deploy-vm.sh -h my-new-vm -c 4 -r 8 -d 50 -o ubuntu2404 -y
```

This creates a VM named "my-new-vm" with:
- 4 CPU cores
- 8 GB RAM
- 50 GB disk space
- Ubuntu 24.04 operating system
- doesnt prompt you to review

### Chaotic
```bash
./deploy-vm.sh -h random -o random -y
```
Use default settings, except pick a random OS and hostname

### I have too much CPU/RAM and I dont know what to do with it all...
```bash
for os in $(./deploy-vm.sh -l); do ./deploy-vm.sh -y -o $os -h test-$os; done
```
Deploy one of each supported OS

### All Options

- `-h` - Hostname/VM name (required)
- `-c` - Number of CPU cores (default: 2)
- `-r` - RAM in GB (default: 2)
- `-d` - Disk size in GB (default: 20)
- `-o` - OS to install (default: rocky9)
- `-y` - Skip confirmation prompt
- `-l` - List available OS options


## Configuration

The default configuration is stored in `~/.config/deploy-vm/default.vars`. This file is created automatically when you first run the script.

Example configuration:

```bash
# settings for deploy-vm script
VM_IMAGE_DIR=/var/lib/libvirt
user=adam
ram=2048
cpu=2
disk_size=20
os=rocky9
ssh_pub_key_file=
BRIDGE=br0
user_data_file=/root/.config/create-vm/user-data.sh
github_user=adamaze
```

### SSH Key Configuration

You can configure SSH keys in two ways:

1. Local key file: Set `ssh_pub_key_file=~/.ssh/id_rsa.pub` in the config file
2. GitHub username: Set `github_user=yourusername` to pull keys from GitHub

## How It Works

1. The script validates your inputs against system resources
2. Downloads the appropriate cloud image if not already cached
3. Creates a new qcow2 image file based on the cloud image
4. Generates cloud-init metadata
5. Creates a cloud-init ISO with user SSH keys
6. Deploys the VM with virt-install

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
