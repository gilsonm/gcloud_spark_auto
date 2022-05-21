# Author: Michael Gilson
# Date: 5/27/21

##################################################################
#
# Functions imported by the workflow driver / controller.
# This file should be sourced in addition to:
# - conf.sh
# - common_lib.sh
# in order for config var defs and common functions.
#
# Assumed to be Google Cloud Shell, or any environment with 
# gcloud/gsutil and needed access perms.
#
##################################################################

function check_for_hail() {

    # check for hail
    # hail valid if it matches in pip3 freeze
    # no version checking is performed

    match=$(pip3 freeze | grep -i hail)

    if [ "$match" != "" ]
    then
        echo "Found hail. $match"
    else
        echo "Looks like hail is not installed."
        echo "- To install. In Google Cloud Shell, invoke: pip3 install hail"
        echo "- If hail has been installed in a python virtual environment, "
        echo -e "\tplease activate that environment and re-run this script."

        if want_to "attempt to run hail anyway"
        then
            return
        else
            exit 2
        fi
    fi
}

function post_deploy_configuration() {

    # requires that prep_and_transfer_payload was run

    echo 'Adjusting user resource limit (# open files) on remote VM to ${USER_FILE_LIMIT}'

    gcloud compute \
        ssh $INSTANCE_VM_NAME \
        --zone $ZONE \
        -- "./remote.sh prebounce"

    echo 'Configuring trio-denovo VM and workflow bucket...'

    # update bucket policy to allow service account to r/w to bucket
    gsutil iam \
        ch \
        serviceAccount:${SERVICE_ACCOUNT_EMAIL}:roles/storage.legacyBucketOwner \
        gs://${BUCKET}

    # setting _the_ service account for a vm requires a bounce
    # also, scope applies to oauth scope for resource type (here, storage)?

    gcloud compute instances stop ${INSTANCE_VM_NAME} --zone $ZONE

    gcloud compute \
        instances set-service-account $INSTANCE_VM_NAME \
        --service-account $SERVICE_ACCOUNT_EMAIL \
        --scopes storage-rw \
        --zone $ZONE

    gcloud compute instances start $INSTANCE_VM_NAME --zone $ZONE
}

function write_bindings_file() {

    # the python var=value pairs binds the condiguration for the entire workflow to the 
    # configuration to the "main" hail script. this file is available on the PYTHONPATH 
    # in the remote context and so importing it gives the bash (master) configuration 
    # values for the run

    echo "lcr_uri = '$LCR_URI'" > $HAIL_CONF_SCRIPT # if existed, clobber whatever was in file
    echo "ped_uri = '$PED_URI'" >> $HAIL_CONF_SCRIPT
    echo "meta_uri = '$META_URI'" >> $HAIL_CONF_SCRIPT
    echo "vcf_uri = '$VCF_URI'" >> $HAIL_CONF_SCRIPT
    echo "vcf_out_uri = '$VCF_OUT_URI'" >> $HAIL_CONF_SCRIPT

}

function poll_until_running() {
    while :
    do
        echo 'Checking VM status...'
        match=$(gcloud compute instances describe $INSTANCE_VM_NAME --zone $ZONE | grep 'status: RUNNING')
        if [ "$match" = "status: RUNNING" ]; 
        then
            break
        fi
        sleep 1
    done
}

#
# Remote control and observation utils
#

function prep_and_transfer_payload() {

    # xfer remote agent that configures vm and runs workflow

    echo "Sending agent to remote VM"

    files="common_lib.sh remote_lib.sh remote.sh conf.sh $MERGE_SCRIPT_LOCAL $SPLITTER_SCRIPT $TDN_PED_XFORM_LOCAL $REMOTE_TEST $TDN_INPUT_ADAPTER $TDN_LINE_PARSER"

    gcloud compute \
        scp $files \
        $INSTANCE_VM_NAME:'~/' \
        --zone=$ZONE

    # recursively copy the tdn/vcf library
    gcloud compute scp --recurse $TDN_VCF_PKG $INSTANCE_VM_NAME:'~/vcf' --zone=$ZONE

    echo "Making agent executable"

    gcloud compute \
        ssh $INSTANCE_VM_NAME \
        --zone $ZONE \
        -- "chmod +x remote.sh"
}

function bootstrap_and_run_workflow() {
    # Handoff control to remote code on vm
    # May have to interact with remote tty

    # make agent entrypoint executable in remote shell

    gcloud compute \
        ssh $INSTANCE_VM_NAME \
        --zone $ZONE \
        -- "./remote.sh"
}

function remote_test() {
    # for rapid testing from Cloud Shell (or any other terminal routable to VM)
    #
    # . conf.sh && . common_lib.sh && . local_lib.sh && remote_test ls
    # 
    # Useful also for any local function, like xfering files if needed: 
    #
    # . conf.sh && . common_lib.sh && . local_lib.sh && prep_and_transfer_payload

    echo "Testing remote with argument: $@"

    # recopy files likely to be involved in whatever being tested
    prep_and_transfer_payload

    # send command to eval in remote bash context

    gcloud compute \
        ssh $INSTANCE_VM_NAME \
        --zone $ZONE \
        -- "./remote.sh $@"
}