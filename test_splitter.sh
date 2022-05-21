#!/bin/bash

cp ../extract_fams_SS.py .

# downloaded ped referenced in conf
# now need to download just a bit of a compatible VCF
# chr22 in the conf is huge and is .gz.

docker run \
    -v $(pwd):"/mnt/" \
    --rm \
    python:3.6-alpine3.12 \
    python3 /mnt/extract_fams_SS.py /mnt/split.ped /mnt/split.vcf split.out 22

if [ -e extract_fams_SS.py ]
then
    rm extract_fams_SS.py
fi