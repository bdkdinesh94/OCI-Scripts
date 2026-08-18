#!/bin/bash

# ============================================================
# OCI DB System OCPU Scaling Script
# Supports both Scale Up and Scale Down
# ============================================================

# -------- Configuration --------
DB_SYSTEM_ID="<DB_SYSTEM_OCID>"
REGION="<OCI_REGION>"
TARGET_OCPUS="<TARGET_OCPUS>"

LOG_FILE="/path/to/update_db_node_shape.log"

# -------- Logging --------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# -------- Validation --------
if [ -z "$DB_SYSTEM_ID" ] || [ "$DB_SYSTEM_ID" = "<DB_SYSTEM_OCID>" ]; then
    log "ERROR: DB_SYSTEM_ID is not configured."
    exit 1
fi

if [ -z "$REGION" ] || [ "$REGION" = "<OCI_REGION>" ]; then
    log "ERROR: REGION is not configured."
    exit 1
fi

if ! [[ "$TARGET_OCPUS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log "ERROR: TARGET_OCPUS must be a valid number."
    exit 1
fi

# -------- Start --------
log "===== Run started: target_ocpus=$TARGET_OCPUS region=$REGION ====="

log "Requesting OCPU change to $TARGET_OCPUS on DB System..."

# -------- Get current state --------
CURRENT_STATE=$(oci db system get \
    --db-system-id "$DB_SYSTEM_ID" \
    --region "$REGION" \
    --query 'data."lifecycle-state"' \
    --raw-output 2>&1)

if [ $? -ne 0 ]; then
    log "ERROR: Unable to retrieve DB System state."
    log "$CURRENT_STATE"
    exit 1
fi

log "Current DB System state: $CURRENT_STATE"

if [ "$CURRENT_STATE" != "AVAILABLE" ]; then
    log "ERROR: DB System is not AVAILABLE. Current state: $CURRENT_STATE"
    exit 1
fi

# -------- Scale DB System --------
oci db system update \
    --db-system-id "$DB_SYSTEM_ID" \
    --shape "VM.Standard3.Flex" \
    --cpu-core-count "$TARGET_OCPUS" \
    --region "$REGION" \
    --wait-for-state AVAILABLE \
    --wait-for-state FAILED \
    --max-wait-seconds 1800 \
    >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

# -------- Result --------
if [ $EXIT_CODE -eq 0 ]; then

    FINAL_OCPUS=$(oci db system get \
        --db-system-id "$DB_SYSTEM_ID" \
        --region "$REGION" \
        --query 'data."cpu-core-count"' \
        --raw-output 2>/dev/null)

    FINAL_STATE=$(oci db system get \
        --db-system-id "$DB_SYSTEM_ID" \
        --region "$REGION" \
        --query 'data."lifecycle-state"' \
        --raw-output 2>/dev/null)

    log "Update completed successfully."
    log "Final OCPU count: $FINAL_OCPUS"
    log "Final lifecycle state: $FINAL_STATE"
    log "Status: Completed"
    log "===== Run finished (exit 0) ====="

else

    log "ERROR: OCPU update failed."
    log "Status: Failed"
    log "===== Run finished (exit $EXIT_CODE) ====="

    exit $EXIT_CODE
fi
