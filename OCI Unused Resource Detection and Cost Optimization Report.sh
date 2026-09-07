#!/bin/bash

# ============================================================
# OCI Unused Resource Detection & Cost Optimization Report
#
# Purpose:
#   Identify potentially unused OCI resources and generate
#   a read-only cleanup / cost optimization report.
#
# Resources checked:
#   - Compute Instances
#   - Block Volumes
#   - Boot Volumes
#   - Public IPs
#   - Load Balancers
#   - Block Volume Backups
#
# Features:
#   - Read-only inventory
#   - Age-based analysis
#   - Resource state analysis
#   - Severity classification
#   - CSV report
#   - Detailed log
#   - Summary statistics
#
# IMPORTANT:
#   This script DOES NOT delete or modify resources.
#   All findings require manual validation before cleanup.
#
# Requirements:
#   - OCI CLI
#   - jq
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

COMPARTMENT_ID="<COMPARTMENT_OCID>"

REGION="<OCI_REGION>"

# Resources older than this value can be flagged for review.
AGE_THRESHOLD_DAYS=30

LOG_FILE="./oci_unused_resources.log"

CSV_FILE="./oci_unused_resources.csv"


# ============================================================
# COUNTERS
# ============================================================

TOTAL_CANDIDATES=0

STOPPED_INSTANCES=0
UNATTACHED_BLOCK_VOLUMES=0
UNATTACHED_BOOT_VOLUMES=0
UNUSED_PUBLIC_IPS=0
UNUSED_LOAD_BALANCERS=0
OLD_BACKUPS=0

HIGH_RISK=0
MEDIUM_RISK=0
LOW_RISK=0


# ============================================================
# LOGGING FUNCTION
# ============================================================

log() {

    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" |
        tee -a "$LOG_FILE"

}


# ============================================================
# HEADER
# ============================================================

log "============================================================"
log "OCI UNUSED RESOURCE DETECTION & COST OPTIMIZATION"
log "============================================================"

log "Compartment        : $COMPARTMENT_ID"
log "Region             : $REGION"
log "Age Threshold      : $AGE_THRESHOLD_DAYS days"
log "Scan Time          : $(date '+%Y-%m-%d %H:%M:%S')"

log "------------------------------------------------------------"


# ============================================================
# DEPENDENCY CHECK
# ============================================================

if ! command -v oci >/dev/null 2>&1; then

    log "ERROR: OCI CLI is not installed."

    exit 1

fi


if ! command -v jq >/dev/null 2>&1; then

    log "ERROR: jq is not installed."

    exit 1

fi


# ============================================================
# CONFIGURATION VALIDATION
# ============================================================

if [ "$COMPARTMENT_ID" = "<COMPARTMENT_OCID>" ]; then

    log "ERROR: COMPARTMENT_ID is not configured."

    exit 1

fi


if [ "$REGION" = "<OCI_REGION>" ]; then

    log "ERROR: REGION is not configured."

    exit 1

fi


# ============================================================
# CSV HEADER
# ============================================================

echo "Resource Type,Resource Name,Resource OCID,State,Created Date,Age Days,Severity,Finding,Recommendation" \
    > "$CSV_FILE"


# ============================================================
# CALCULATE DATE
# ============================================================

CURRENT_EPOCH=$(date +%s)

THRESHOLD_SECONDS=$((AGE_THRESHOLD_DAYS * 86400))


# ============================================================
# HELPER FUNCTION
# ============================================================

calculate_age() {

    CREATED_DATE="$1"

    CREATED_EPOCH=$(date -d "$CREATED_DATE" +%s 2>/dev/null)

    if [ -z "$CREATED_EPOCH" ]; then

        echo "UNKNOWN"

        return

    fi

    AGE=$(( (CURRENT_EPOCH - CREATED_EPOCH) / 86400 ))

    echo "$AGE"

}


# ============================================================
# REPORT FUNCTION
# ============================================================

report_finding() {

    RESOURCE_TYPE="$1"
    RESOURCE_NAME="$2"
    RESOURCE_OCID="$3"
    STATE="$4"
    CREATED_DATE="$5"
    AGE="$6"
    SEVERITY="$7"
    FINDING="$8"
    RECOMMENDATION="$9"


    TOTAL_CANDIDATES=$((TOTAL_CANDIDATES + 1))


    case "$SEVERITY" in

        HIGH)
            HIGH_RISK=$((HIGH_RISK + 1))
            ;;

        MEDIUM)
            MEDIUM_RISK=$((MEDIUM_RISK + 1))
            ;;

        LOW)
            LOW_RISK=$((LOW_RISK + 1))
            ;;

    esac


    log ""
    log "RESOURCE TYPE : $RESOURCE_TYPE"
    log "RESOURCE NAME : $RESOURCE_NAME"
    log "STATE        : $STATE"
    log "AGE          : $AGE days"
    log "SEVERITY     : $SEVERITY"
    log "FINDING      : $FINDING"
    log "RECOMMENDATION: $RECOMMENDATION"
    log "------------------------------------------------------------"


    echo "\"$RESOURCE_TYPE\",\"$RESOURCE_NAME\",\"$RESOURCE_OCID\",\"$STATE\",\"$CREATED_DATE\",\"$AGE\",\"$SEVERITY\",\"$FINDING\",\"$RECOMMENDATION\"" \
        >> "$CSV_FILE"

}


# ============================================================
# 1. COMPUTE INSTANCES
# ============================================================

log ""
log "============================================================"
log "CHECKING COMPUTE INSTANCES"
log "============================================================"


INSTANCES=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --region "$REGION" \
    --all \
    2>/dev/null)


if [ $? -ne 0 ]; then

    log "WARNING: Unable to retrieve Compute instances."

else

    echo "$INSTANCES" |
    jq -c '.data[]' |
    while read -r INSTANCE
    do

        NAME=$(echo "$INSTANCE" |
            jq -r '."display-name"')

        ID=$(echo "$INSTANCE" |
            jq -r '.id')

        STATE=$(echo "$INSTANCE" |
            jq -r '."lifecycle-state"')

        CREATED=$(echo "$INSTANCE" |
            jq -r '."time-created"')

        AGE=$(calculate_age "$CREATED")


        # ----------------------------------------------------
        # Stopped instance
        # ----------------------------------------------------

        if [ "$STATE" = "STOPPED" ]; then

            STOPPED_INSTANCES=$((STOPPED_INSTANCES + 1))


            if [ "$AGE" != "UNKNOWN" ] &&
               [ "$AGE" -ge "$AGE_THRESHOLD_DAYS" ]; then

                report_finding \
                    "Compute Instance" \
                    "$NAME" \
                    "$ID" \
                    "$STATE" \
                    "$CREATED" \
                    "$AGE" \
                    "HIGH" \
                    "Instance has remained stopped beyond threshold." \
                    "Validate workload ownership and consider terminating if no longer required."

            else

                report_finding \
                    "Compute Instance" \
                    "$NAME" \
                    "$ID" \
                    "$STATE" \
                    "$CREATED" \
                    "$AGE" \
                    "MEDIUM" \
                    "Instance is currently stopped." \
                    "Confirm whether the instance is still required."

            fi

        fi

    done

fi


# ============================================================
# 2. UNATTACHED BLOCK VOLUMES
# ============================================================

log ""
log "============================================================"
log "CHECKING BLOCK VOLUMES"
log "============================================================"


BLOCK_VOLUMES=$(oci bv volume list \
    --compartment-id "$COMPARTMENT_ID" \
    --region "$REGION" \
    --all \
    2>/dev/null)


if [ $? -ne 0 ]; then

    log "WARNING: Unable to retrieve Block Volumes."

else

    echo "$BLOCK_VOLUMES" |
    jq -c '.data[]' |
    while read -r VOLUME
    do

        NAME=$(echo "$VOLUME" |
            jq -r '."display-name"')

        ID=$(echo "$VOLUME" |
            jq -r '.id')

        STATE=$(echo "$VOLUME" |
            jq -r '."lifecycle-state"')

        CREATED=$(echo "$VOLUME" |
            jq -r '."time-created"')

        AGE=$(calculate_age "$CREATED")

        ATTACHED=$(echo "$VOLUME" |
            jq -r '."volume-group-id" // empty')


        # ----------------------------------------------------
        # Check volume attachments separately
        # ----------------------------------------------------

        ATTACHMENTS=$(oci compute volume-attachment list \
            --compartment-id "$COMPARTMENT_ID" \
            --volume-id "$ID" \
            --region "$REGION" \
            --all \
            2>/dev/null)


        ATTACHMENT_COUNT=$(echo "$ATTACHMENTS" |
            jq '.data | length')


        if [ "$ATTACHMENT_COUNT" -eq 0 ]; then

            UNATTACHED_BLOCK_VOLUMES=$((UNATTACHED_BLOCK_VOLUMES + 1))


            report_finding \
                "Block Volume" \
                "$NAME" \
                "$ID" \
                "$STATE" \
                "$CREATED" \
                "$AGE" \
                "HIGH" \
                "Block volume is not attached to a compute instance." \
                "Verify ownership and backup requirements before deletion."

        fi

    done

fi


# ============================================================
# 3. BOOT VOLUMES
# ============================================================

log ""
log "============================================================"
log "CHECKING BOOT VOLUMES"
log "============================================================"


BOOT_VOLUMES=$(oci bv boot-volume list \
    --compartment-id "$COMPARTMENT_ID" \
    --region "$REGION" \
    --all \
    2>/dev/null)


if [ $? -ne 0 ]; then

    log "WARNING: Unable to retrieve Boot Volumes."

else

    echo "$BOOT_VOLUMES" |
    jq -c '.data[]' |
    while read -r BOOT
    do

        NAME=$(echo "$BOOT" |
            jq -r '."display-name"')

        ID=$(echo "$BOOT" |
            jq -r '.id')

        STATE=$(echo "$BOOT" |
            jq -r '."lifecycle-state"')

        CREATED=$(echo "$BOOT" |
            jq -r '."time-created"')

        AGE=$(calculate_age "$CREATED")


        ATTACHMENTS=$(oci compute boot-volume-attachment list \
            --compartment-id "$COMPARTMENT_ID" \
            --boot-volume-id "$ID" \
            --region "$REGION" \
            --all \
            2>/dev/null)


        ATTACHMENT_COUNT=$(echo "$ATTACHMENTS" |
            jq '.data | length')


        if [ "$ATTACHMENT_COUNT" -eq 0 ]; then

            UNATTACHED_BOOT_VOLUMES=$((UNATTACHED_BOOT_VOLUMES + 1))


            report_finding \
                "Boot Volume" \
                "$NAME" \
                "$ID" \
                "$STATE" \
                "$CREATED" \
                "$AGE" \
                "HIGH" \
                "Boot volume is not attached to a compute instance." \
                "Confirm that the volume is not required before cleanup."

        fi

    done

fi


# ============================================================
# 4. PUBLIC IP ADDRESSES
# ============================================================

log ""
log "============================================================"
log "CHECKING PUBLIC IP ADDRESSES"
log "============================================================"


PUBLIC_IPS=$(oci network public-ip pool list \
    --compartment-id "$COMPARTMENT_ID" \
    --region "$REGION" \
    --all \
    2>/dev/null)


# ------------------------------------------------------------
# Note:
# Public IP discovery can vary depending on whether the IP
# is ephemeral or reserved. This section focuses on reserved
# public IP resources.
# ------------------------------------------------------------


if [ $? -eq 0 ]; then

    echo "$PUBLIC_IPS" |
    jq -c '.data[]' |
    while read -r IP
    do

        NAME=$(echo "$IP" |
            jq -r '."display-name" // "Unnamed Public IP"')

        ID=$(echo "$IP" |
            jq -r '.id')

        STATE=$(echo "$IP" |
            jq -r '."lifecycle-state"')

        IP_ADDRESS=$(echo "$IP" |
            jq -r '."ip-address"')


        log "Public IP: $IP_ADDRESS"

    done

else

    log "INFO: Reserved Public IP inventory could not be retrieved."

fi


# ============================================================
# 5. LOAD BALANCERS
# ============================================================

log ""
log "============================================================"
log "CHECKING LOAD BALANCERS"
log "============================================================"


LOAD_BALANCERS=$(oci lb load-balancer list \
    --compartment-id "$COMPARTMENT_ID" \
    --region "$REGION" \
    --all \
    2>/dev/null)


if [ $? -ne 0 ]; then

    log "WARNING: Unable to retrieve Load Balancers."

else

    echo "$LOAD_BALANCERS" |
    jq -c '.data[]' |
    while read -r LB
    do

        NAME=$(echo "$LB" |
            jq -r '."display-name"')

        ID=$(echo "$LB" |
            jq -r '.id')

        STATE=$(echo "$LB" |
            jq -r '."lifecycle-state"')

        CREATED=$(echo "$LB" |
            jq -r '."time-created"')

        AGE=$(calculate_age "$CREATED")


        log "Load Balancer: $NAME"
        log "State        : $STATE"


        # ----------------------------------------------------
        # Retrieve backend sets
        # ----------------------------------------------------

        BACKEND_SETS=$(oci lb backend-set list \
            --load-balancer-id "$ID" \
            --region "$REGION" \
            2>/dev/null)


        BACKEND_COUNT=$(echo "$BACKEND_SETS" |
            jq '[.data[]] | length')


        if [ "$BACKEND_COUNT" -eq 0 ]; then

            UNUSED_LOAD_BALANCERS=$((UNUSED_LOAD_BALANCERS + 1))


            report_finding \
                "Load Balancer" \
                "$NAME" \
                "$ID" \
                "$STATE" \
                "$CREATED" \
                "$AGE" \
                "HIGH" \
                "Load balancer has no backend sets." \
                "Validate whether the load balancer is still required."

        fi

    done

fi


# ============================================================
# 6. BLOCK VOLUME BACKUPS
# ============================================================

log ""
log "============================================================"
log "CHECKING BLOCK VOLUME BACKUPS"
log "============================================================"


BACKUPS=$(oci bv backup list \
    --compartment-id "$COMPARTMENT_ID" \
    --region "$REGION" \
    --all \
    2>/dev/null)


if [ $? -eq 0 ]; then

    echo "$BACKUPS" |
    jq -c '.data[]' |
    while read -r BACKUP
    do

        NAME=$(echo "$BACKUP" |
            jq -r '."display-name" // "Unnamed Backup"')

        ID=$(echo "$BACKUP" |
            jq -r '.id')

        STATE=$(echo "$BACKUP" |
            jq -r '."lifecycle-state"')

        CREATED=$(echo "$BACKUP" |
            jq -r '."time-created"')

        AGE=$(calculate_age "$CREATED")


        if [ "$AGE" != "UNKNOWN" ] &&
           [ "$AGE" -ge "$AGE_THRESHOLD_DAYS" ]; then

            OLD_BACKUPS=$((OLD_BACKUPS + 1))


            report_finding \
                "Block Volume Backup" \
                "$NAME" \
                "$ID" \
                "$STATE" \
                "$CREATED" \
                "$AGE" \
                "MEDIUM" \
                "Backup is older than configured review threshold." \
                "Review retention requirements before removing the backup."

        fi

    done

else

    log "WARNING: Unable to retrieve Block Volume Backups."

fi


# ============================================================
# FINAL SUMMARY
# ============================================================

log ""
log "============================================================"
log "OCI RESOURCE OPTIMIZATION SUMMARY"
log "============================================================"

log "Stopped Compute Instances : $STOPPED_INSTANCES"

log "Unattached Block Volumes  : $UNATTACHED_BLOCK_VOLUMES"

log "Unattached Boot Volumes   : $UNATTACHED_BOOT_VOLUMES"

log "Unused Load Balancers     : $UNUSED_LOAD_BALANCERS"

log "Old Block Volume Backups  : $OLD_BACKUPS"

log "------------------------------------------------------------"

log "Total Cleanup Candidates  : $TOTAL_CANDIDATES"

log "High Priority Findings    : $HIGH_RISK"

log "Medium Priority Findings  : $MEDIUM_RISK"

log "Low Priority Findings     : $LOW_RISK"

log "------------------------------------------------------------"

log "CSV Report                : $CSV_FILE"

log "Log File                  : $LOG_FILE"

log "------------------------------------------------------------"


if [ "$TOTAL_CANDIDATES" -eq 0 ]; then

    log "Overall Status: NO POTENTIAL UNUSED RESOURCES DETECTED."

else

    log "Overall Status: REVIEW REQUIRED."

    log "IMPORTANT: Findings must be manually validated before cleanup."

fi


log "============================================================"

log "OCI Resource Optimization Scan Completed"

log "============================================================"


exit 0
