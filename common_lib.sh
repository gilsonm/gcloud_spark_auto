####################################################
# common functions for control and remote contexts #
####################################################

function gsuri_to_filename() {
    echo $1 | awk '{n=split($0,uri,"/");print uri[n]}'
}

function in_proj_root() {
    [ -d .git ] && [ -d cloud ] && [ -d docs ] && [ -f README.md ]
}

function want_to() {
    action_msg=$1
    while true; do
        read -p "Do you wish to ${action_msg}?: " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

