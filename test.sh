. conf.sh
. common_lib.sh
. local_lib.sh

# Use this to run code with current state of local context (the imports)
# Like a function from local_lib:
#
# $ ./test.sh prep_and_transfer_payload
#
# To test remotely, use the remote_test local function to pass commands to the remote application shell context.
# For instance, here we're setting an environment variable that is referenced by the function split_by_trio.
#
# $ ./test.sh remote_test LOCAL_PED=wgs-trios.ped split_by_trio
#
# If you don't use this script, to bring your local or remote shell into app context, you must do shit like:
#
# $ . conf.sh && . common_lib.sh && . local_lib.sh && prep_and_transfer_payload

if [ $# -eq 0 ]
then
    echo "Pass an argument to run in app context."
else
    echo "Running '$@' in app context."
    eval "$@"
fi
