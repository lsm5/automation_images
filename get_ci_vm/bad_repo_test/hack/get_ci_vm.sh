#!/usr/bin/env bash

set -e

RED="\e[1;36;41m"
YEL="\e[1;33;44m"
NOR="\e[0m"
USAGE_WARNING="
${YEL}WARNING: This will not work without local sudo access to run podman,${NOR}
         ${YEL}and prior authorization to use the oci-seccomp-bpf-hook GCP project. Also,${NOR}
         ${YEL}possession of the proper ssh private key is required.${NOR}
"
# TODO: Many/most of these values should come from .cirrus.yml
ZONE="us-central1-c"
CPUS="2"
MEMORY="4Gb"
DISK="200"
PROJECT="oci-seccomp-bpf-hook"
GOSRC="/var/tmp/go/src/github.com/containers/oci-seccomp-bpf-hook"
GCLOUD_IMAGE=${GCLOUD_IMAGE:-quay.io/cevich/gcloud_centos:latest}
GCLOUD_SUDO=${GCLOUD_SUDO-sudo}
SSHUSER="root"

# Shared tmp directory between container and us
TMPDIR=$(mktemp -d --tmpdir $(basename $0)_tmpdir_XXXXXX)

SECCOMPHOOKROOT=$(realpath "$(dirname $0)/../")
# else: Assume $PWD is the root of the oci-seccomp-bpf-hook repository
[[ "$SECCOMPHOOKROOT" != "/" ]] || SECCOMPHOOKROOT=$PWD

# Command shortcuts save some typing (assumes $SECCOMPHOOKROOT is subdir of $HOME)
PGCLOUD="$GCLOUD_SUDO podman run -it --rm -e AS_ID=$UID -e AS_USER=$USER --security-opt label=disable -v $TMPDIR:$HOME -v $HOME/.config/gcloud:$HOME/.config/gcloud -v $HOME/.config/gcloud/ssh:$HOME/.ssh -v $SECCOMPHOOKROOT:$SECCOMPHOOKROOT $GCLOUD_IMAGE --configuration=oci-seccomp-bpf-hook --project=$PROJECT"
SCP_CMD="$PGCLOUD compute scp --zone=$ZONE"


showrun() {
    if [[ "$1" == "--background" ]]
    then
        shift
        # Properly escape any nested spaces, so command can be copy-pasted
        echo '+ '$(printf " %q" "$@")' &' > /dev/stderr
        "$@" &
        echo -e "${RED}<backgrounded>${NOR}"
    else
        echo '+ '$(printf " %q" "$@") > /dev/stderr
        "$@"
    fi
}

cleanup() {
    RET=$?
    set +e
    wait

    # Not always called from an exit handler, but should always exit when called
    exit $RET
}
trap cleanup EXIT

delvm() {
    echo -e "\n"
    echo -e "\n${YEL}Offering to Delete $VMNAME ${RED}(Might take a minute or two)${NOR}"
    echo -e "\n${YEL}Note: It's safe to answer N, then re-run script again later.${NOR}"
    showrun $CLEANUP_CMD  # prompts for Yes/No
    cleanup
}

image_hints() {
    _BIS=$(egrep -m 1 '_BUILT_IMAGE_SUFFIX:[[:space:]+"[[:print:]]+"' \
        "$SECCOMPHOOKROOT/.cirrus.yml" | cut -d: -f 2 | tr -d '"[:blank:]')
    egrep '[[:space:]]+[[:alnum:]].+_CACHE_IMAGE_NAME:[[:space:]+"[[:print:]]+"' \
        "$SECCOMPHOOKROOT/.cirrus.yml" | cut -d: -f 2 | tr -d '"[:blank:]' | \
        sed -r -e "s/\\\$[{]_BUILT_IMAGE_SUFFIX[}]/$_BIS/" | sort -u
}

show_usage() {
    echo -e "\n${RED}ERROR: $1${NOR}"
    echo -e "${YEL}Usage: $(basename $0) <image_name>${NOR}"
    echo ""
    if [[ -r ".cirrus.yml" ]]
    then
        echo -e "${YEL}Some possible image_name values (from .cirrus.yml):${NOR}"
        image_hints
        echo ""
    fi
    exit 1
}

get_env_vars() {
    python3 -c '
import yaml
env=yaml.load(open(".cirrus.yml"), Loader=yaml.SafeLoader)["env"]
keys=[k for k in env if "ENCRYPTED" not in str(env[k])]
for k,v in env.items():
    v=str(v)
    if "ENCRYPTED" not in v:
        print("{0}=\"{1}\"".format(k, v))
    '
}

parse_args(){
    echo -e "$USAGE_WARNING"

    if [[ "$USER" =~ "root" ]]
    then
        show_usage "This script must be run as a regular user."
    fi

    ENVS="$(get_env_vars)"
    IMAGE_NAME="$1"
    if [[ -z "$IMAGE_NAME" ]]
    then
        show_usage "No image-name specified."
    fi

    SETUP_CMD="env $ENVS $GOSRC/contrib/cirrus/setup.sh"
    VMNAME="${VMNAME:-${USER}-${IMAGE_NAME}}"
    CREATE_CMD="$PGCLOUD compute instances create --zone=$ZONE --image-project=libpod-218412 --image=${IMAGE_NAME} --custom-cpu=$CPUS --custom-memory=$MEMORY --boot-disk-size=$DISK --labels=in-use-by=$USER $VMNAME"
    SSH_CMD="$PGCLOUD compute ssh --zone=$ZONE $SSHUSER@$VMNAME"
    CLEANUP_CMD="$PGCLOUD compute instances delete --zone=$ZONE --delete-disks=all $VMNAME"
}

##### main

[[ "${SECCOMPHOOKROOT%%${SECCOMPHOOKROOT##$HOME}}" == "$HOME" ]] || \
    show_usage "Repo clone must be sub-dir of $HOME: $SECCOMPHOOKROOT"

cd "$SECCOMPHOOKROOT"

parse_args "$@"

# Ensure mount-points and data directories exist on host as $USER.  Also prevents
# permission-denied errors during cleanup() b/c `sudo podman` created mount-points
# owned by root.
mkdir -p $TMPDIR/${SECCOMPHOOKROOT##$HOME}
mkdir -p $TMPDIR/.ssh
mkdir -p {$HOME,$TMPDIR}/.config/gcloud/ssh
chmod 700 {$HOME,$TMPDIR}/.config/gcloud/ssh $TMPDIR/.ssh

cd $SECCOMPHOOKROOT

# Attempt to determine if named 'oci-seccomp-bpf-hook' gcloud configuration exists
showrun $PGCLOUD info > $TMPDIR/gcloud-info
if egrep -q "Account:.*None" $TMPDIR/gcloud-info
then
    echo -e "\n${YEL}WARNING: Can't find gcloud configuration for 'oci-seccomp-bpf-hook', running init.${NOR}"
    echo -e "         ${RED}Please choose '#1: Re-initialize' and 'login' if asked.${NOR}"
    echo -e "         ${RED}Please set Compute Region and Zone (if asked) to 'us-central1-b'.${NOR}"
    echo -e "         ${RED}DO NOT set any password for the generated ssh key.${NOR}"
    showrun $PGCLOUD init --project=$PROJECT --console-only --skip-diagnostics

    # Verify it worked (account name == someone@example.com)
    $PGCLOUD info > $TMPDIR/gcloud-info-after-init
    if egrep -q "Account:.*None" $TMPDIR/gcloud-info-after-init
    then
        echo -e "${RED}ERROR: Could not initialize 'oci-seccomp-bpf-hook' configuration in gcloud.${NOR}"
        exit 5
    fi

    # If this is the only config, make it the default to avoid persistent warnings from gcloud
    [[ -r "$HOME/.config/gcloud/configurations/config_default" ]] || \
        ln "$HOME/.config/gcloud/configurations/config_oci-seccomp-bpf-hook" \
           "$HOME/.config/gcloud/configurations/config_default"
fi

# Couldn't make rsync work with gcloud's ssh wrapper: ssh-keys generated on the fly
TARBALL=$VMNAME.tar.bz2
echo -e "\n${YEL}Packing up local repository into a tarball.${NOR}"
showrun --background tar cjf $TMPDIR/$TARBALL --warning=no-file-changed --exclude-vcs-ignores -C $SECCOMPHOOKROOT .

trap delvm INT  # Allow deleting VM if CTRL-C during create
# This fails if VM already exists: permit this usage to re-init
echo -e "\n${YEL}Trying to create a VM named $VMNAME\n${RED}(might take a minute/two.  Errors ignored).${NOR}"
showrun $CREATE_CMD || true # allow re-running commands below when "delete: N"

# Any subsequent failure should prompt for VM deletion
trap delvm EXIT

echo -e "\n${YEL}Retrying for 30s for ssh port to open (may give some errors)${NOR}"
trap 'COUNT=9999' INT
ATTEMPTS=10
for (( COUNT=1 ; COUNT <= $ATTEMPTS ; COUNT++ ))
do
    if $SSH_CMD --command "true"; then break; else sleep 3s; fi
done
if (( COUNT > $ATTEMPTS ))
then
    echo -e "\n${RED}Failed${NOR}"
    exit 7
fi
echo -e "${YEL}Got it${NOR}"

echo -e "\n${YEL}Removing and re-creating $GOSRC on $VMNAME.${NOR}"
showrun $SSH_CMD --command "rm -rf $GOSRC"
showrun $SSH_CMD --command "mkdir -p $GOSRC"

echo -e "\n${YEL}Transferring tarball to $VMNAME.${NOR}"
wait
showrun $SCP_CMD $HOME/$TARBALL $SSHUSER@$VMNAME:/tmp/$TARBALL

echo -e "\n${YEL}Unpacking tarball into $GOSRC on $VMNAME.${NOR}"
showrun $SSH_CMD --command "tar xjf /tmp/$TARBALL -C $GOSRC"

echo -e "\n${YEL}Removing tarball on $VMNAME.${NOR}"
showrun $SSH_CMD --command "rm -f /tmp/$TARBALL"

echo -e "\n${YEL}Executing environment setup${NOR}"
showrun $SSH_CMD --command "$SETUP_CMD"

VMIP=$($PGCLOUD compute instances describe $VMNAME --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo -e "\n${YEL}Connecting to $VMNAME${NOR}\nPublic IP Address: $VMIP\n${RED}(option to delete VM upon logout).${NOR}\n"
showrun $SSH_CMD -- -t "cd $GOSRC && exec env $ENVS bash -il"
