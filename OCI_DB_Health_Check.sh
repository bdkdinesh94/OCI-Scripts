#!/bin/bash

# ============================================================
# OCI DB System Health Check Automation
# Read-only health check using OCI CLI
# ============================================================

# -------- Configuration --------
DB_SYSTEM_ID="<DB_SYSTEM_OCID>"
REGION="<OCI_REGION>"

LOG_FILE="/path/to/oci_db_health_check.log"

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

log "============================================================"
log "OCI DB SYSTEM HEALTH CHECK"
log "============================================================"
log "DB System ID : $DB_SYSTEM_ID"
log "Region       : $REGION"
log "Check Time   : $(date '+%Y-%m-%d %H:%M:%S')"
log "------------------------------------------------------------"

# -------- Retrieve DB System information --------
DB_INFO=$(oci db system get \
    --db-system-id "$DB_SYSTEM_ID" \
    --region "$REGION" \
    2>&1)

if [ $? -ne 0 ]; then
    log "ERROR: Unable to retrieve DB System information."
    log "$DB_INFO"
    exit 1
fi

# -------- Extract details --------
DISPLAY_NAME=$(echo "$DB_INFO" | jq -r '.data."display-name"')
LIFECYCLE_STATE=$(echo "$DB_INFO" | jq -r '.data."lifecycle-state"')
SHAPE=$(echo "$DB_INFO" | jq -r '.data.shape')
OCPUS=$(echo "$DB_INFO" | jq -r '.data."cpu-core-count"')
MEMORY=$(echo "$DB_INFO" | jq -r '.data."memory-size-in-gbs"')
STORAGE=$(echo "$DB_INFO" | jq -r '.data."data-storage-size-in-gbs"')
RECO_STORAGE=$(echo "$DB_INFO" | jq -r '.data."reco-storage-size-in-gb"')
DB_VERSION=$(echo "$DB_INFO" | jq -r '.data.version')
DB_EDITION=$(echo "$DB_INFO" | jq -r '.data."database-edition"')
NODE_COUNT=$(echo "$DB_INFO" | jq -r '.data."node-count"')
OS_VERSION=$(echo "$DB_INFO" | jq -r '.data."os-version"')
LISTENER_PORT=$(echo "$DB_INFO" | jq -r '.data."listener-port"')

# -------- Display information --------
log "DB System Name       : $DISPLAY_NAME"
log "Lifecycle State      : $LIFECYCLE_STATE"
log "Shape                : $SHAPE"
log "OCPU Count           : $OCPUS"
log "Memory               : ${MEMORY} GB"
log "Data Storage         : ${STORAGE} GB"
log "RECO Storage         : ${RECO_STORAGE} GB"
log "Database Version     : $DB_VERSION"
log "Database Edition     : $DB_EDITION"
log "Node Count           : $NODE_COUNT"
log "OS Version           : $OS_VERSION"
log "Listener Port        : $LISTENER_PORT"

log "------------------------------------------------------------"

# -------- Health evaluation --------
HEALTH_STATUS="HEALTHY"

if [ "$LIFECYCLE_STATE" != "AVAILABLE" ]; then
    HEALTH_STATUS="UNHEALTHY"
    log "WARNING: DB System lifecycle state is $LIFECYCLE_STATE"
fi

if [ "$OCPUS" = "null" ] || [ -z "$OCPUS" ]; then
    HEALTH_STATUS="WARNING"
    log "WARNING: Unable to determine OCPU count."
fi

if [ "$MEMORY" = "null" ] || [ -z "$MEMORY" ]; then
    HEALTH_STATUS="WARNING"
    log "WARNING: Unable to determine memory configuration."
fi

log "------------------------------------------------------------"
log "Overall Health Status : $HEALTH_STATUS"
log "============================================================"

# -------- Exit status --------
if [ "$HEALTH_STATUS" = "HEALTHY" ]; then
    log "Health check completed successfully."
    exit 0
else
    log "Health check completed with warnings/errors."
    exit 1
fi
