#!/usr/bin/env bash

# This script is set as, and intended to run as the `orphanvms` container's
# entrypoint.  It searches for actibe VM instances with an "old" `creation`
# timestamp.

set -eo pipefail

# shellcheck source=imgts/lib_entrypoint.sh
source /usr/local/bin/lib_entrypoint.sh

# set this to 1 to enable
A_DEBUG="${A_DEBUG:-0}"
if ((A_DEBUG)); then msg "Warning: Debugging is enabled"; fi
EVERYTHING=${EVERYTHING:-0}  # set to '1' for testing

req_env_var GCPJSON GCPNAME GCPPROJECTS

# Try not to make any output when no orphan VMs are found
GCLOUD="$GCLOUD --quiet --verbosity=error"
TOO_OLD='3 days ago'  # Detect Friday Orphans on Monday
if ((EVERYTHING)); then
    TOO_OLD="3 seconds ago"
fi

NOW=$(date +%s)
THRESHOLD=$(date --date="$TOO_OLD" --iso-8601=minute)
# Format Ref: https://cloud.google.com/sdk/gcloud/reference/topic/formats
FORMAT='value[quote](name,lastStartTimestamp,labels)'
# Filter Ref: https://cloud.google.com/sdk/gcloud/reference/topic/filters
# List fields cmd: `gcloud compute instances list --format=yaml --limit=1`
FILTER="status!=TERMINATED AND lastStartTimestamp<$THRESHOLD AND labels.list(show='persistent')!~'true'"

# shellcheck disable=SC2154,SC2153
for GCPPROJECT in $GCPPROJECTS; do
    # Despite the --quiet flag, this will still emit 'Activated service account...'
    # to stdout.  Since stdout triggers the nag-email to  be sent, we must filter
    # only non-matching output.  Unfortunately, if if there is no output for some
    # reason, this will cause grep to fail.  Ignore this, since the next gcloud
    # command to follow will complain loudly if the credentials aren't sufficient.
    gcloud_init |& grep -Eiv '^Activated service account credentials for:' || true

    if ((A_DEBUG)); then msg "Examining $GCPPROJECT"; fi
    OUTPUT=$(mktemp -p '' orphanvms_${GCPPROJECT}_XXXXX)
    echo "Orphaned $GCPPROJECT VMs:" > $OUTPUT

    # Ref: https://cloud.google.com/compute/docs/images/create-delete-deprecate-private-images#deprecating_an_image
    $GCLOUD compute instances list --format="$FORMAT" --filter="$FILTER" | \
        while read name lastStartTimestamp labels
        do
            if ((A_DEBUG)); then
                msg "    VM $name started $lastStartTimestamp labeled $labels"
            fi
            if [[ -z "$name" ]] || [[ -z "$lastStartTimestamp" ]]; then
                if ((A_DEBUG)); then msg "    IGNORING EMPTY NAME OR TIMESTAMP"; fi
                continue
            fi
            started_at=$(date --date=$lastStartTimestamp +%s)
            age_days=$((($NOW - $started_at) / (60 * 60 * 24)))
            # running in a child-process, must buffer into file.
            echo -e "* VM $name running $age_days days with labels '$labels'" >> $OUTPUT
            if ((A_DEBUG)); then msg "    FLAGGING VM AS ORPHANED"; fi
        done

    if [[ $(wc -l $OUTPUT | awk '{print $1}') -gt 1 ]]; then
        cat $OUTPUT
    fi
done
