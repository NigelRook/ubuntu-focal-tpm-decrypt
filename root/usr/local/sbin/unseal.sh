#!/bin/sh
if key=$(tpm2_unseal -c 0x81000000 -p pcr:sha256:0,2,4,7,8,9,14); then
    echo -n $key
else
    /lib/cryptsetup/askpass "Automatic unlock failed, enter encrypted volume key"
fi
