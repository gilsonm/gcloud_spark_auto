# Author: Michael C Gilson
# Date: 5/13/21
# 
# From trial and online research.
# Could eventually be moved into 
#   i) Dockerfile
#   ii) Google Compute Engine image
#   iii) VM cloud-init setup in Deployment Manager template
#
# These were most helpful:
# https://docs.docker.com/engine/install/debian/
# https://docs.docker.com/engine/install/linux-postinstall/

function prebounce() {
    # this scope is for work that requires a VM bounce (restart) to take affect

    # update userland open filehandle limits for all users
    RESOURCE_LIMIT_DEF_FILE="/etc/security/limits.conf"

    echo "[PREBOUNCE]: prebounce. Altering ${RESOURCE_LIMIT_DEF_FILE}"

    sudo chmod 646 "${RESOURCE_LIMIT_DEF_FILE}" # setting __6 was absolutely required. SCP of this file was incredibly difficult auth/perms-wise.
    sudo echo "* soft nofile ${USER_FILE_LIMIT}" > "${RESOURCE_LIMIT_DEF_FILE}"
    sudo echo "* hard nofile ${USER_FILE_LIMIT}" >> "${RESOURCE_LIMIT_DEF_FILE}"

    echo "[PREBOUNCE]: prebounce. New contents of ${RESOURCE_LIMIT_DEF_FILE}"
    
    sudo cat $RESOURCE_LIMIT_DEF_FILE
}

function init_vm() {
    # scope for commands to execute after 
    #   1. VM bounce and 
    #   2. remote agent/config/dependencies have been transferred and are available (running here)

    sudo apt-get update -y
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y

    # install google cloud monitoring agent; notice this is being phased out
    curl -sSO https://dl.google.com/cloudagents/add-monitoring-agent-repo.sh
    sudo bash add-monitoring-agent-repo.sh --also-install

    # docker
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo groupadd docker
    sudo usermod -aG docker $USER

    # enable docker service and show status to workflow operator
    sudo systemctl enable docker.service
    sudo systemctl enable containerd.service
    sudo service docker status

    # build htslib 1.3 and dependencies from official release
    sudo apt-get install -y autoconf automake make gcc perl zlib1g-dev libbz2-dev liblzma-dev libcurl4-gnutls-dev libssl-dev
    sudo apt install -y build-essential # <~~ necessary on debian 9. would not have found on internet.
    curl -L https://github.com/samtools/htslib/releases/download/1.13/htslib-1.13.tar.bz2 > htslib-1.13.tar.bz2
    tar -xjvf htslib-1.13.tar.bz2
    pushd .
    cd htslib-1.13
    ./configure
    make
    sudo make install
    popd
    bgzip # just show that these are callable, or error o.w.
    tabix

    # build the c vcf.gz merger linking to libz, producing file: vcf_gz_merge
    gcc -Wall -pthread  $MERGE_SCRIPT_REMOTE -lm -lz -std=c99 -Wextra -o $MERGER_BINARY
    sudo apt-get install -y dos2unix

    # install GNU parallel to exploit multi-core parallelism
    sudo apt-get install -y parallel

    # show how many cores gnu parallel detected
    NCORES_DETECTED=$(parallel --number-of-cores)
    echo "[INIT_VM]: GNU parallel: ${NCORES_DETECTED} cores detected."
}

function setup() {
    # scope to prepare execution context for docker container
    # e.g. 
    #  - gsutil download data
    #  - gsutil set a flag in a runtime key for this run in GCS
    #  - mount a filesystem
    #  - etc.
    echo "[SETUP]: Setup scope"

    gsutil cp $WORKFLOW_INPUT_PED .

    # Copy vcfs from tmp bucket to VM
    # filename with the suffix of the path, after last pathsep

    gsutil cp -R $DST_URI .
}

function run() {
    streaming_merge
    split_by_trio
    trio_denovo
    report
}

function streaming_merge() {
    echo "[MERGE]: Streaming download, filter, merge of gzip vcfs."

    VCF_GZ_FIFO=pipe
    VCF_GZ=input.vcf.gz

    #
    # TODO: It's possible we can use a second fifo to stream directly into the splitter. Something to try.
    #
    DO_HEADER=true
    for s in $(gsutil ls $DST_URI);
    do
        echo "[MERGE]: Processing $s"

        STATS_FILE="${s}.stats.tsv"

        # use a fifo to stream the vcf.gz data from cloud storage into the merger c binary for streamlined IO
        mkfifo $VCF_GZ_FIFO

        # stream the gzipp'd vcf into the fifo pipe as a process in the background.
        # data from gsutil will fill the pipe/buffer until full, and then the code 
        # will block on a file.write type call. That is, until the merger program 
        # starts consuming bytes from the buffer, freeing up capacity for gsutil to 
        # dl some more bytes of the vcf.
        gsutil cat $s > $VCF_GZ_FIFO &

        # start the merger program in the foreground, passing in the fifo pipe that 
        # gsutil will use to pass data to the merger in memory, and the merger program 
        # will itself park the data on disk (or pass it to the splitter through another 
        # pipe)
        ./$MERGER_BINARY $VCF_GZ_FIFO $STATS_FILE $DO_HEADER >> $MERGED_VCF

        # remove fifo pipe. can these be re-used in subsequent executions?
        if [ -e $VCF_GZ_FIFO ];
        then
            rm $VCF_GZ_FIFO
        fi

        echo "[MERGE]: $s" >> $REPORT_FILE
        cat $STATS_FILE >> $REPORT_FILE
        echo "[MERGE]: Done."

        DO_HEADER=false # do not signal to merger binary to print header in any subsequence VCFs
    done

    # htslib-1.3 installed to debian-9 vm in init_vm scope. so we have bgzip.
    bgzip -f $MERGED_VCF # produces ${MERGED_VCF}.gz
}

function split_by_trio() {
    # Step 3. Split by trio.
    #
    # Split merged-by-chr VCFs into trio VCFs, for further MV filtering

    LOCAL_PED=$(gsuri_to_filename $WORKFLOW_INPUT_PED)
    echo $LOCAL_PED

    python $SPLITTER_SCRIPT_NAME \
        $LOCAL_PED \
        $MERGED_VCF_GZ \
        $OUT_PREFIX

    # Report number of variants/MVs in each trio
    for vcf in $(ls $OUT_PREFIX);
    do
        MVS=$(cat $vcf | grep -v '#' | wc -l)
        echo "[SPLIT]: ${vcf}: $MVS" >> $REPORT_FILE
    done
}

function trio_denovo() {
    # Step 4. Filter mvs and call putative de novos.
    #
    # i. Transform the ped from GATK-like format to TDN pedigree format
    echo "[DENOVO]: Transforming the ped from GATK-like format to TDN pedigree format"

    # these should be put into a folder
    python $TDN_PED_XFORM_REMOTE -i $LOCAL_PED -o $PED_PREFIX # makes wgs.trios.<fam_id>-<chi_idx>.ped
    mv ${PED_PREFIX}.*.ped $OUT_PREFIX # move them in with the vcfs

    # ii. Filter MVs to putative de novos using our TrioDeNovo container
    mkdir -p $LOCAL_OUTPUT_VCF_DIR
    for VCF in $(find $OUT_PREFIX -type f -name '*.vcf');
    do
        # compute matcing pedigree filename from VCF filename path components
        PED=$(echo $VCF | awk 'BEGIN{FS="/"}{split($2,a,"."); printf("%s.ped",a[1])}')
        PED="${OUT_PREFIX}/${PED_PREFIX}.${PED}"

        # ensure the name resolution worked
        if [ -e $VCF ]; then echo "Found: $VCF"; fi
        if [ -e $PED ]; then echo "Found: $PED"; fi

        # now build the output filename from the VCF filename
        TRIO_CHR_EXT=$(basename $VCF)
        TRIO_CHR="${TRIO_CHR_EXT%.*}"
        OUT="${OUT_PREFIX}/${TRIO_CHR}.denovos.vcf"

        # scrub the VCF
        SCRUBBED_VCF=scrubbed.vcf
        READY_VCF=ready.vcf
        #python InputAdapters.py -i $VCF -o $SCRUBBED_VCF
        echo "grep -v '##' $VCF > $READY_VCF" >> $TDN_PARALLEL_CMDS

        # The InputAdapters removes most variants from splitter. so I just used the grep filter.
        # Looks like it's "working". But it sometimes complains: No GL or PL field .... at #CHROM
        # However it does not complain on every VCF/trio.
        #
        # ^~~~~ this is because the #CHROM line is inside the VCF records!
        #
        # BUT: this may just be a warning. Do we even need to remove it?

        echo "[DENOVO]: Producing: $OUT"

        echo sudo docker run \
            --rm \
            -v "$(pwd)":/triodenovo/ex \
            lindsayliang/triodenovo \
            /triodenovo/triodenovo-fix/bin/triodenovo \
            --ped ex/${PED} \
            --in_vcf ex/${READY_VCF} \
            --out_vcf ex/${OUT} \
            --minDepth 10 \
            --chrX X \
            --mixed_vcf_records >> $TDN_PARALLEL_CMDS

        # if [ -e $OUT ]; 
        # then
        #     NLINES=$(wc -l $OUT)
        #     echo "[DENOVO]: $OUT file produced. There are ${NLINES} lines."
        # else
        #     echo "[DENOVO]: $OUT not produced!"
        # fi
    done

    parallel < $TDN_PARALLEL_CMDS

    # Add to report
    #
    # Compare the # of MV's to the number of denovos.
    # Nother there was a filter during the merge I think.
}

function teardown() {
    # scope to clean up runtime context and store results
    # e.g. 
    #  - gsutil upload data
    #  - unmount a filesystem
    #  - etc.
    echo "[DOWN]: Teardown scope"

    # USE: parallel composite uploads with gsutil to egress data to workflow bucket.
    #      what a thoughtful suggestion from gsutil. big ups.
    #
    # ==> NOTE: You are uploading one or more large file(s), which would run
    # significantly faster if you enable parallel composite uploads. This
    # feature can be enabled by editing the
    # "parallel_composite_upload_threshold" value in your .boto
    # configuration file. However, note that if you do this large files will
    # be uploaded as `composite objects
    # <https://cloud.google.com/storage/docs/composite-objects>`_,which
    # means that any user who downloads such objects will need to have a
    # compiled crcmod installed (see "gsutil help crcmod"). This is because
    # without a compiled crcmod, computing checksums on composite objects is
    # so slow that gsutil disables downloads of composite objects.

    gsutil cp $REPORT_FILE $WKFLW_OUTPUT

    # tar and gzip any of the egressed data
    # then use parallel up for the chunks

    gsutil cp $LOCAL_OUTPUT_VCF $WKFLW_OUTPUT_VCF
}

function run_lifecycle() {
    init_vm
    setup
    run
    teardown
}

function heartbeat() {
    # executed via SSH from a control endpoint
    echo "[BEATS]: Heartbeat"
}
