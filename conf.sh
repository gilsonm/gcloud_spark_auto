######################################################################
# These bindings will be available in both control and remote scopes #
######################################################################

# resources
REGION=us-east4
ZONE=us-east4-b
DEPLOYMENT_NAME=wgs-denovos-pipeline
DEPLOYMENT_CONF=pipeline_resources.context.yaml
PROJECT_ID=
SERVICE_ACCOUNT_NAME=
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
INSTANCE_VM_NAME=trio-denovo
BUCKET=workflow-bucket-name

# hail
HAIL_CLSTR_NAME=denovo-hail
HAIL_SCRIPT=../wgs_pre_processing_vcf_v2.py
HAIL_CONF_SCRIPT=hail_denovo_conf.py

# args to $HAIL_SCRIPT (via hailctl dataproc submit ..)
VCF_URI=
VCF_OUT_URI=
LCR_URI=
PED_URI=
META_URI=

INPUT_VCF=
INPUT_IDX=
INPUT_PED=

WORKFLOW_INPUT_VCF=gs://${BUCKET}/examples/wgs-trios.vcf.gz # bucket/key URI for input VCF
WORKFLOW_INPUT_IDX=gs://${BUCKET}/examples/wgs-trios.gz.tbi # bucket/key URI for input index
WORKFLOW_INPUT_PED=gs://${BUCKET}/examples/wgs-trios.ped # the suffix of this URI, after the last pathsep /, must be a valid ext4 filename

SPLITTER_SCRIPT=
SPLITTER_SCRIPT_NAME=
MERGE_SCRIPT_REMOTE=
MERGE_SCRIPT_LOCAL=
MERGER_BINARY=vcf_gz_merge
VCF_GZ_FIFO=merge-pipe # this has to match what the c merger expects. todo: add as an arg to the merger rather than hardcoding.
OUT_PREFIX=trios.out # on remote FS
PED_PREFIX=wgs.trios
USER_FILE_LIMIT=10000 # should be > than safeFhCount variable in splitter script. we could do some tricks to make it get the value from this conf. Later.

TDN_PARALLEL_CMDS=tdn.parallel.sh

TDN_PED_XFORM_LOCAL=../tdn_ped_converter.py
TDN_PED_XFORM_REMOTE=tdn_ped_converter.py
TDN_INPUT_ADAPTER=../triodenovo/InputAdapters.py
TDN_LINE_PARSER=../triodenovo/VCFLineParser.py
TDN_VCF_PKG=../triodenovo/vcf # copy recursively

MERGED_VCF=merged.vcf
MERGED_VCF_GZ="${MERGED_VCF}.gz"

REMOTE_TEST=test.sh

REPORT_FILE=report.txt
WORKFLOW_REPORT=gs://${BUCKET}/$REPORT_FILE 

LOCAL_OUTPUT_VCF_DIR=tdn.out.vcf # temporary, VM-localized output of TDN
WKFLW_OUTPUT_VCF=gs://${BUCKET}/examples/tdn.wrkflw.vcf # bucket/key URI for GCS location of TDN output
FINAL_OUTPUT_VCF=

SRC_FILES="""
"""

DST_URI=gs://${BUCKET}/multisamp_vcfs/