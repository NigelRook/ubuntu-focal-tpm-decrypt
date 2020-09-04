Start point: fresh ubuntu 20.04 install on my Dell Latitude 7410 created by
allowing the installer to erase and repartition the disk, with the LVM and
encryption advnaced options selected. Secure Boot enabled.

Followed [docs/kelderek.md](docs/kelderek.md)

Saved initial pcrs to allow watching for changes (pcrs not comitted)

`sudo tpm2_pcrread > pcrs/0_initial.txt`
