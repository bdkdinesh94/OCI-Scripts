#!/bin/bash

# ============================================================
# OCI Cloud Guard Findings Report
# Read-only reporting using OCI CLI
# ============================================================

# -------- Configuration --------
COMPARTMENT_ID="<COMPARTMENT_OCID>"
REGION="<OCI_REGION>"

LOG_FILE="/path/to/oci_cloudguard_findings.log"

# -------- Logging --------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# -------- Validation --------
if [ -z "$COMPARTMENT_ID" ] || [ "$COMPARTMENT_ID" = "<COMPARTMENT_OCID>" ]; then
    log "ERROR: COMPARTMENT_ID is not configured."
    exit 1
fi

if [ -z "$REGION" ] || [ "$REGION" = "<OCI_REGION>" ]; then
    log "ERROR: REGION is not configured."
    exit 1
fi

log "============================================================"
log "OCI CLOUD GUARD FINDINGS REPORT"
log "============================================================"
log "Compartment : $COMPARTMENT_ID"
log "Region      : $REGION"
log "Report Time : $(date '+%Y-%m-%d %H:%M:%S')"
log "------------------------------------------------------------"

# -------- Retrieve Cloud Guard problems --------
PROBLEMS=$(oci cloud-guard problem list \
    --compartment-id "$COMPARTMENT_ID" \
    --region "$REGION" \
    --all \
    2>&1)

if [ $? -ne 0 ]; then
    log "ERROR: Unable to retrieve Cloud Guard problems."
    log "$PROBLEMS"
    exit 1
fi

# -------- Check for problems --------
PROBLEM_COUNT=$(echo "$PROBLEMS" | jq '.data.items | length')

if [ "$PROBLEM_COUNT" -eq 0 ]; then
    log "No Cloud Guard problems found."
    log "Overall Security Status: HEALTHY"
    log "============================================================"
    exit 0
fi

log "Total Problems Found: $PROBLEM_COUNT"
log "------------------------------------------------------------"

# -------- Generate report --------
echo "$PROBLEMS" | jq -r '
.data.items[] |
[
    ."problem-id",
    ."risk-level",
    ."lifecycle-state",
    ."problem-name",
    ."resource-name",
    ."resource-type"
] |
@tsv
' | while IFS=$'\t' read -r PROBLEM_ID RISK_LEVEL STATE PROBLEM_NAME RESOURCE RESOURCE_TYPE
do
    log "Problem ID    : $PROBLEM_ID"
    log "Risk Level    : $RISK_LEVEL"
    log "State         : $STATE"
    log "Problem       : $PROBLEM_NAME"
    log "Resource      : $RESOURCE"
    log "Resource Type : $RESOURCE_TYPE"
    log "------------------------------------------------------------"
done

# -------- Risk summary --------
CRITICAL_COUNT=$(echo "$PROBLEMS" | jq '[.data.items[] | select(."risk-level" == "CRITICAL")] | length')
HIGH_COUNT=$(echo "$PROBLEMS" | jq '[.data.items[] | select(."risk-level" == "HIGH")] | length')
MEDIUM_COUNT=$(echo "$PROBLEMS" | jq '[.data.items[] | select(."risk-level" == "MEDIUM")] | length')
LOW_COUNT=$(echo "$PROBLEMS" | jq '[.data.items[] | select(."risk-level" == "LOW")] | length')

log "RISK SUMMARY"
log "------------------------------------------------------------"
log "CRITICAL : $CRITICAL_COUNT"
log "HIGH     : $HIGH_COUNT"
log "MEDIUM   : $MEDIUM_COUNT"
log "LOW      : $LOW_COUNT"
log "------------------------------------------------------------"

if [ "$CRITICAL_COUNT" -gt 0 ] || [ "$HIGH_COUNT" -gt 0 ]; then
    log "Overall Security Status: ATTENTION REQUIRED"
    log "============================================================"
    exit 1
else
    log "Overall Security Status: NO HIGH/CRITICAL FINDINGS"
    log "============================================================"
    exit 0
fi
