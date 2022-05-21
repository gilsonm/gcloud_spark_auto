#!/bin/bash

# Author: Michael C Gilson
# Date: 5/13/21

# import function libraries for (this) control module
. common_lib.sh
. local_lib.sh

# import the run configuration bindings
. conf.sh

if want_to "run hail"
then
    echo "Looking for hail.."

    check_for_hail # check for hail install with pip3, guide user and prompt to continue if missing

    echo "Creating dataproc cluster.."

    hailctl dataproc start \
        --region $REGION \
        $HAIL_CLSTR_NAME

    gcloud config set dataproc/region us-east4

    echo "Submitting work.."

    write_bindings_file

    hailctl dataproc submit \
        --pyfiles $HAIL_CONF_SCRIPT \
        $HAIL_CLSTR_NAME $HAIL_SCRIPT

    hailctl dataproc stop \
        $HAIL_CLSTR_NAME
fi

if want_to "create trio-denovo vm and bucket"
then
    # create temporary resources for workflow
    gcloud deployment-manager deployments create "${DEPLOYMENT_NAME}" --config "${DEPLOYMENT_CONF}"

    # this will list the active (non-deleted) deployments, you can verify $DEPLOYMENT_NAME is there
    gcloud deployment-manager deployments list

    # transfer our agent to remote, configure bucket, set service acct of vm in order to talk to bucket, bounce vm
    prep_and_transfer_payload
    post_deploy_configuration
    poll_until_running
fi

if want_to "transfer from SRC_BUCKET to WRKFLW_BUCKET"
then
    echo "Copying files from source bucket to workflow bucket..."

    # move inputs to merge script from source locations to tmp-workflow-bucket for processing
    gsutil cp $INPUT_VCF $WORKFLOW_INPUT_VCF
    gsutil cp $INPUT_IDX $WORKFLOW_INPUT_IDX
    gsutil cp $INPUT_PED $WORKFLOW_INPUT_PED 

    # Copy list of vcfs to a prefix in tmp bucket
    for s in $SRC_FILES;
    do
        gsutil cp $s $DST_URI
    done

    # necessary to make the service account co-owner (or reader) of objects just copied 
    # by control identity to workflow bucket. apparently google rules engine evaluates 
    # resource policies from most-to-least granular, and the object perms restrict the 
    # bucket perms, even for ownership scope

    echo "Updating (co)owner of objects"

    gsutil iam \
        ch -r \
        serviceAccount:${SERVICE_ACCOUNT_EMAIL}:legacyObjectOwner \
        gs://${BUCKET}/examples/

    gsutil iam \
        ch -r \
        serviceAccount:${SERVICE_ACCOUNT_EMAIL}:legacyObjectOwner \
        ${DST_URI}
fi

if want_to "run remote code"
then
    bootstrap_and_run_workflow
fi

#
# Here is the scope where you would transfer files from WRKFLW_BUCKET->DST_BUCKET
#
if want_to "transfer results from temporary bucket?"
then
    gsutil cp $WKFLW_OUTPUT_VCF $FINAL_OUTPUT_VCF
fi

if want_to "tear down resources"
then
    echo "Clearing $BUCKET for removal"
    gsutil -m rm -f "gs://${BUCKET}/"
    # tear-down all resources associated with computation
    gcloud deployment-manager deployments delete "${DEPLOYMENT_NAME}" 
fi