Start point: fresh ubuntu 20.04 install on my Dell Latitude 7410 created by
allowing the installer to erase and repartition the disk, with the LVM and
encryption advnaced options selected. Secure Boot enabled.

Followed [docs/kelderek.md](docs/kelderek.md)

Saved initial pcrs to allow watching for changes (pcrs not comitted)

`sudo tpm2_pcrread > pcrs/00_initial.txt`

Reboot, success, was not asked for passowrd.

dump pcrs again

`sudo tpm2_pcrread > pcrs/01_after-kelderek.txt`

PCR 9 changed. PCR 9 is GRUB's files PCR, see here:

https://www.gnu.org/software/grub/manual/grub/html_node/Measured-Boot.html

Most likely explanation: GRUB is hashing the initramfs file contents on boot and
adding it to the pcr. On the plus side, that gives us a way to ensure nobody's
meddling with it. On the minus side, the TPM clearly isn't blocing us from
reading from it if that does change.

What else does the TPM not block? Two things to explore:

1. justanormaltechie noted that by adding break=mount to the initramfs command
   you could get a root busybox shell capable of running tpm2-getkey. That's no
   good, we need to check that
2. What if I boot to a usb with tpm2-tools? Have we actually saved our key with
   a policy that prevents anybody else from reading it out?
