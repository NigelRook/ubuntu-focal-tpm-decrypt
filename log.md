Start point: fresh ubuntu 20.04 install on my Dell Latitude 7410 created by
allowing the installer to erase and repartition the disk, with the LVM and
encryption advnaced options selected. Secure Boot enabled.

I also checked the use proprietary drivers option during installation. This
caused my next boot to be into MokManager.  Based on
https://wiki.ubuntu.com/UEFI/SecureBoot I believe that checking the proprietary
drvers checkbox causes an additional keypair to be installed in grub which
allows ubuntu to sign kernels compiled locally. That's relevant because we end
up tinkering with initramfs and that may well be signed. I haven't tested
whether things still work if proprietary drivers aren't enabled and MokManager
hasn't been run.

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

Booted to ubuntu live usb, installed tpm2-tools, was able to extract the key
with `tpm2_nvread -C 0x40000001 0x1500016`. So this ain't good enough. We're
safe if somebody moves the encrypted disk to another pc, but we're not if they
boot from a usb.

https://medium.com/@pawitp/full-disk-encryption-on-arch-linux-backed-by-tpm-2-0-c0892cab9704
is actually doing stuff that uses policies, lets see if we can adapt that. We're
on tpm2 > 4.0.0 so we need the commands here:
https://medium.com/@pawitp/its-certainly-annoying-that-tpm2-tools-like-to-change-their-command-line-parameters-d5d0f4351206

Lets create a policy sha:

`sudo tpm2_createpolicy --policy-pcr -l sha256:0,2,4,7,8,9,14 -L policy.digest`

This'll lock a lot of PCRs. 0 is the bios, 2 is less clear, seen things
suggesting it stops oeople changing the boot options in the bios. 4 is grub
itself, 7 is secure boot settings, 8 is grub config, 9 is all the files grub
loads, and 14 is the set of keys grub uses to verify kernel signatures.

Create a primary object under the endorsement hierachy (not fully sure what this actually means):

`sudo tpm2_createprimary -C e -g sha256 -G rsa -c primary.context`

Create a child object that we can load into the tpm (root.key should be your luks key):

`sudo tpm2_create -g sha256 -u obj.pub -r obj.priv -C primary.context -L policy.digest -a "noda|adminwithpolicy|fixedparent|fixedtpm" -i root.key`

Load it into the tpm:

`sudo tpm2_load -C primary.context -u obj.pub -r obj.priv -c load.context`

Persist it in the tpm at permanent handle 0x81000000

`sudo tpm2_evictcontrol -C o -c load.context 0x81000000`

clean up

`sudo rm load.context obj.priv obj.pub policy.digest primary.context`

Check that we can get it out:

`sudo tpm2_unseal -c 0x81000000 -p pcr:sha256:0,2,4,7,8,9,14`
