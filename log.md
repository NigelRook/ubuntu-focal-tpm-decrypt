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

When booting from a bootable usb tpm2_unseal no longer works, great!

It also doesn't work when adding break=bottom as a kernel param and attempting
to unseal from the initramfs debug busybox, excellent. That's ssecure now!

Lets try using it to boot. Create a script at `/usr/local/sbin/unseal.sh` containing

```
#!/bin/sh
tpm2_unseal -c 0x81000000 -p pcr:sha256:0,2,4,7,8,9,14
```

Set the permissions:

```
sudo chown root:root /usr/local/sbin/unseal.sh
sudo chmod 0750 /usr/local/sbin/unseal.sh
```

Set the keyscript in `/etc/crypttab` by ensuring it contains `keyscript=/usr/local/sbin/unseal.sh`

Add tpm2_unseal to initramfs by adding the following to `/etc/initramfs-tools/hooks/tpm2-decryptkey`:

`copy_exec /usr/bin/tpm2_unseal`

And build the updated initramfs:

```
sudo mkinitramfs -o /boot/initrd.img-`uname -r` `uname -r`
```

Which fails, as we'd expect, because initramfs has changed so we'd expect pcr 9
to be different. And checking the PCRs that's exactly what happened. Recovering
from this involves editing the grub config and adding `break=mount`, then
rewriting unseal.sh to contain

```
#!/bin/sh
/lib/cryptsetup/askpass "Password"
```

After `exit` the keyscript will then instead offer a password prompt entering
the original luks key configured during installation will unlock the volume.

Lets add askpass as a fallback in our keyscript:

```
#!/bin/sh
key=$(tpm2_unseal -c 0x81000000 -p pcr:sha256:0,2,4,7,8,9,14)
if $?; then
    echo $key
else
    /lib/cryptsetup/askpass "Automatic unlock failed, enter encrypted volume key"
fi
```

After running mkinitramfs again and rebooting, we get prompted for a password
just like we did before configuring a keyscript. That's a solid fallback.

Lets re-add our key to the TPM using the following script:

```
#!/bin/bash

if [[ ! -f "$1" ]]; then
    echo "Usage: seal-root-key keyfile"
    exit 1
fi

PCR_POLICY="sha256:0,2,4,7,8,9,14"
PERMANENT_HANDLE=0x81000000

set -e

STATE_DIR=${STATE_DIR:-"/var/local/tpm-root-key"}
mkdir -p -m 0750 $STATE_DIR
cd $STATE_DIR

# Create policy if not present
[[ -f "policy.digest" ]] || tpm2_createpolicy --policy-pcr -l $PCR_POLICY -L policy.digest
# Create primary object context if not present
[[ -f "primary.context" ]] || tpm2_createprimary -C e -g sha256 -G rsa -c primary.context
# Create child object
tpm2_create -g sha256 -u obj.pub -r obj.priv -C primary.context -L policy.digest -a "noda|adminwithpolicy|fixedparent|fixedtpm" -i $1
# Load into tpm
tpm2_load -C primary.context -u obj.pub -r obj.priv -c load.context
# Remove old key if present
tpm2_readpublic -c $PERMANENT_HANDLE && tpm2_evictcontrol -C o -c $PERMANENT_HANDLE
# Persist object in tpm
tpm2_evictcontrol -C o -c load.context $PERMANENT_HANDLE
# Clean up
rm load.context obj.priv obj.pub
```

Hmm, that didn't work, I got prompted. PCRs match last time, I wonder what's going on...

Lets try getting the key from the tpm...

`sudo tpm2_unseal -c 0x81000000 -p pcr:sha256:0,2,4,7,8,9,14`

Seems fine, and if we check that against the volume?

`sudo tpm2_unseal -c 0x81000000 -p pcr:sha256:0,2,4,7,8,9,14 | sudo cryptsetup luksOpen --test-passphrase /dev/nvme0n1p3`

Works fine. Running the keyscript?

`sudo /usr/local/sbin/unwrap.sh`

Aha, we got 

```
/usr/local/sbin/unseal.sh: 3: 0: not found
Enter encrypted volume key (press TAB for no echo) 
```

Bug in that scipt, this should work:

```
#!/bin/sh
if key=$(tpm2_unseal -c 0x81000000 -p pcr:sha256:0,2,4,7,8,9,14); then
    echo -n $key
else
    /lib/cryptsetup/askpass "Automatic unlock failed, enter encrypted volume key"
fi
```

Rebuild intramfs again:

```
sudo mkinitramfs -o /boot/initrd.img-`uname -r` `uname -r`
```

Rebooting now gets us the prompt, but `seal-root-key` fails at `tpm2_create`.
Turns out we can't preserve `primary.context`. Removing

`[[ -f "primary.context" ]] || `

makes the script work.

But rebooting still gives a prompt. We're still not unsealing correctly. Even if
I retun `seal-root-key` and try to unseal again we still don't unseal correctly.
Removing policy.digest fixes that, we need to always recreate that too. Remove
this from the script:

`[[ -f "policy.digest" ]] || `

Success, after running `seal-root-key` again ee can reboot without a prompt.

Our key is still hanging around unsecured in the tpm nvram, we need to get rid
of that.

`sudo tpm2_nvundefine -C 0x40000001 0x1500016`
