#!/bin/bash

# import the run configuration bindings
. conf.sh

# import function libraries for (this) remote module
. common_lib.sh
. remote_lib.sh

DEFAULT_CMD="run_lifecycle"

if [ $# -eq 0 ]
then
    eval $DEFAULT_CMD
else
    eval "$@" # this will still work with prebounce. the default should be runlifecycle for now and I think that is it.
fi