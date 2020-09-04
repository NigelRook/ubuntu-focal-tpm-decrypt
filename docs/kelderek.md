## Notes

This file contains steps for getting decrypt from tpm2 working found here:

https://run.tournament.org.il/ubuntu-18-04-and-tpm2-encrypted-system-disk/

It's largely copied from kelderek's comments on that page, with his later
improvements merged in. I also reversed his removal of certain extra parameters
from tpm2_ commands, since removal looked like it marginally lowered security.

## Steps

```
# Full disk encryption on Linux using LUKS+TPM2
#
# Heavily modified, but based on:
# https://run.tournament.org.il/ubuntu-18-04-and-tpm2-encrypted-system-disk/
#
# Created 2020/07/13
# This assumes a fresh Ubuntu 20.04 install that was configured with full disk LUKS encryption at install so it requires a password to unlock the disk at boot.
# This will create a new 64 character random password, add it to LUKS, store it in the TPM, and modify initramfs to pull it from the TPM automatically at boot.

# Install tpm2-tools

apt install tpm2-tools

# Define the area on the TPM where we will store a 64 character key

sudo tpm2_nvdefine -s 64 -C 0x40000001 -a 0x2000A 0x1500016

# If the previous line generated an error, you may need to run this to clear the area of the TPM we are using, then try the tpm2_nvdefine line again.
# sudo tpm2_nvundefine 0x1500016
# sudo tpm2_nvdefine -s 64 -C 0x40000001 -a 0x2000A 0x1500016

# Generate a 64 char alphanumeric key

cat /dev/urandom | tr -dc a-zA-Z0-9 | head -c 64 > root.key

# Store the key in the TPM

sudo tpm2_nvwrite -C 0x40000001 -i root.key 0x1500016

# Print the saved key and the one on the TPM for comparison. echo is used to add a newline char to the output

echo Sanity check – these values should match. If they don’t DO NOT PROCEED!
echo root.key file contents: `cat root.key`
echo The value stored in TPM: `tpm2_nvread -C 0x40000001 0x1500016`

# IF AND ONLY IF the root.key and TPM output are the same, remove the root.key file for extra security. Maybe save it somewhere secure first for recovery purposes

rm root.key

# Add the key to LUKS. Check /etc/crypttab to find the correct device, mine was in UUID=... format but it could be /dev/...!

sudo cryptsetup luksAddKey UUID=device_id root.key

# Create a key recovery script at /usr/local/bin/tpm2-getkey with just the following two lines:

#!/bin/sh
tpm2_nvread -C 0x40000001 0x1500016

# Set the script owner and permissions

sudo chown root: /usr/local/sbin/tpm2-getkey
sudo chmod 750 /usr/local/sbin/tpm2-getkey

# Create /etc/initramfs-tools/hooks/tpm2-decryptkey with the following contents:

#!/bin/sh
PREREQ=””
prereqs()
{
  echo “$PREREQ”
}
case $1 in
  prereqs)
    prereqs
    exit 0
    ;;
esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/bin/tpm2_nvread
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0.0.0
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0
exit 0

# Set the file owner and permissions

sudo chown root: /etc/initramfs-tools/hooks/tpm2-decryptkey
sudo chmod 755 /etc/initramfs-tools/hooks/tpm2-decryptkey

# Backup /etc/crypttab, then add this to the end of the line for the boot volume: ,keyscript=/usr/local/sbin/tpm2-getkey
# e.g. this line: sda3_crypt UUID=d4a5a9a4-a2da-4c2e-a24c-1c1f764a66d2 none luks,discard
# should become : sda3_crypt UUID=d4a5a9a4-a2da-4c2e-a24c-1c1f764a66d2 none luks,discard,keyscript=/usr/local/sbin/tpm2-getkey

# Copy the current initramfs just in case, then create the new initramfs with auto unlocking

sudo cp /boot/initrd.img-`uname -r` /boot/initrd.img-`uname -r`.orig
sudo mkinitramfs -o /boot/initrd.img-`uname -r` `uname -r`

# If booting fails, press esc at the beginning of the boot to get to the grub menu. Edit the Ubuntu entry and add .orig to end of the initrd line to boot to the original initramfs this one time.

# e.g. initrd /initrd.img-5.4.0-40-generic.orig
```
