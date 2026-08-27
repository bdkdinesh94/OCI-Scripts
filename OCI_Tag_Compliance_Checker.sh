#!/bin/bash

# ============================================================
# OCI Resource Tag Governance and Compliance Checker (v2)
#
# Purpose:
#   Scan OCI resources tenancy-wide (or per compartment) and
#   validate mandatory tagging requirements using OCI Resource
#   Search and OCI CLI.
#
# What's new in v2 vs the original script:
#   - CLI argument parsing (no more hand-editing the file)
#   - External JSON policy file (tags + allowed values), with
#     built-in fallback defaults if no policy file is given
#   - Full pagination (handles >1000 resources safely)
#   - Retry logic for transient OCI CLI/API failures
#   - Proportional compliance scoring (not just 100/80/50)
#   - Resource-type exclude list
#   - Multiple defined-tag namespaces supported at once
#   - Outputs: CSV report + JSON summary + simple HTML report
#   - Verbose/quiet modes, colorized console output
#   - Configurable pass/fail thresholds for exit code
#
# IMPORTANT:
#   This script is READ-ONLY. It does not create, update, or
#   delete OCI resources or tags.
#
# Requirements:
#   - OCI CLI (configured with a working profile)
#   - jq
#   - Permission to run resource search in the target scope
#
# Usage:
#   ./oci_tag_compliance_v2.sh -r us-ashburn-1
#   ./oci_tag_compliance_v2.sh -r us-ashburn-1 -c ocid1.compartment.oc1..xxxx
#   ./oci_tag_compliance_v2.sh -r us-ashburn-1 -p policy.json -o ./reports
#   ./oci_tag_compliance_v2.sh --help
# ============================================================

set -u
set -o pipefail

SCRIPT_VERSION="2.0.0"

# ============================================================
# DEFAULTS (overridable via CLI flags)
# ============================================================

REGION=""
COMPARTMENT_ID=""
OUTPUT_DIR="./oci_tag_compliance_output"
POLICY_FILE=""
PROFILE="DEFAULT"
VERBOSE=0
PAGE_LIMIT=1000
MAX_RETRIES=3
RETRY_DELAY=5

# Exit-code thresholds: script exits non-zero if overall score
# falls below this, or if any resource is NON_COMPLIANT and
# --strict is passed.
FAIL_BELOW_SCORE=100
STRICT_MODE=0

# Resource types to skip entirely (space-separated), e.g. tags
# don't make sense on some resource types.
EXCLUDED_TYPES=""

# ============================================================
# DEFAULT POLICY (used if no --policy file is supplied)
# ============================================================
# A policy file (JSON) can override all of this. Expected shape:
# {
#   "namespaces": ["Governance"],
#   "required_tags": ["Environment","Project","Owner","CostCenter","Purpose"],
#   "allowed_values": {
#     "Environment": ["PROD","NON-PROD","DEV","TEST","UAT"],
#     "Purpose": ["APPLICATION","DATABASE","NETWORK","SECURITY","BACKUP","MONITORING","STORAGE"]
#   }
# }

DEFAULT_NAMESPACES=("Governance")
DEFAULT_REQUIRED_TAGS=("Environment" "Project" "Owner" "CostCenter" "Purpose")

# ============================================================
# COLORS (disabled automatically if not a terminal)
# ============================================================

if [ -t 1 ]; then
    C_RED="\033[0;31m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[0;33m"
    C_BLUE="\033[0;34m"
    C_RESET="\033[0m"
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

# ============================================================
# USAGE
# ============================================================

usage() {
    cat <<EOF
OCI Resource Tag Governance & Compliance Checker v${SCRIPT_VERSION}

Usage: $0 -r REGION [options]

Required:
  -r, --region REGION           OCI region (e.g. us-ashburn-1)

Optional:
  -c, --compartment OCID        Limit scan to this compartment (default: entire tenancy)
  -p, --policy FILE             JSON policy file (namespaces, required tags, allowed values)
  -o, --output-dir DIR          Directory for reports (default: ${OUTPUT_DIR})
  -P, --profile NAME            OCI CLI profile to use (default: DEFAULT)
  -x, --exclude TYPES           Space/comma separated resource types to skip
  -f, --fail-below SCORE        Exit non-zero if overall score < SCORE (default: ${FAIL_BELOW_SCORE})
  -s, --strict                  Exit non-zero if ANY resource is NON_COMPLIANT
  -v, --verbose                 Verbose console output
  -h, --help                    Show this help and exit

Examples:
  $0 -r us-ashburn-1
  $0 -r us-ashburn-1 -c ocid1.compartment.oc1..xxxx -o ./reports
  $0 -r us-ashburn-1 -p policy.json -x "Bucket,VolumeBackup" -s
EOF
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--region) REGION="$2"; shift 2 ;;
        -c|--compartment) COMPARTMENT_ID="$2"; shift 2 ;;
        -p|--policy) POLICY_FILE="$2"; shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -P|--profile) PROFILE="$2"; shift 2 ;;
        -x|--exclude) EXCLUDED_TYPES="$2"; shift 2 ;;
        -f|--fail-below) FAIL_BELOW_SCORE="$2"; shift 2 ;;
        -s|--strict) STRICT_MODE=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$REGION" ]; then
    echo -e "${C_RED}ERROR: --region is required.${C_RESET}" >&2
    usage
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="${OUTPUT_DIR}/oci_tag_compliance_${TIMESTAMP}.log"
CSV_FILE="${OUTPUT_DIR}/oci_tag_compliance_${TIMESTAMP}.csv"
JSON_FILE="${OUTPUT_DIR}/oci_tag_compliance_${TIMESTAMP}.json"
HTML_FILE="${OUTPUT_DIR}/oci_tag_compliance_${TIMESTAMP}.html"

# ============================================================
# LOGGING
# ============================================================

log() {
    local level="${2:-INFO}"
    local color="$C_RESET"
    case "$level" in
        ERROR) color="$C_RED" ;;
        WARN)  color="$C_YELLOW" ;;
        PASS)  color="$C_GREEN" ;;
        DEBUG) color="$C_BLUE" ;;
    esac
    local line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $1"
    echo "$line" >> "$LOG_FILE"
    if [ "$VERBOSE" -eq 1 ] || [ "$level" != "DEBUG" ]; then
        echo -e "${color}${line}${C_RESET}"
    fi
}

vlog() {
    [ "$VERBOSE" -eq 1 ] && log "$1" "DEBUG"
    return 0
}

# ============================================================
# DEPENDENCY CHECK
# ============================================================

for cmd in oci jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "Required command '$cmd' is not installed or not on PATH." "ERROR"
        exit 1
    fi
done

# ============================================================
# LOAD POLICY (external JSON file, or fall back to defaults)
# ============================================================

if [ -n "$POLICY_FILE" ]; then
    if [ ! -f "$POLICY_FILE" ]; then
        log "Policy file not found: $POLICY_FILE" "ERROR"
        exit 1
    fi
    if ! jq empty "$POLICY_FILE" >/dev/null 2>&1; then
        log "Policy file is not valid JSON: $POLICY_FILE" "ERROR"
        exit 1
    fi
    mapfile -t NAMESPACES < <(jq -r '.namespaces[]?' "$POLICY_FILE")
    mapfile -t REQUIRED_TAGS < <(jq -r '.required_tags[]?' "$POLICY_FILE")
    POLICY_JSON=$(cat "$POLICY_FILE")

    [ ${#NAMESPACES[@]} -eq 0 ] && NAMESPACES=("${DEFAULT_NAMESPACES[@]}")
    [ ${#REQUIRED_TAGS[@]} -eq 0 ] && REQUIRED_TAGS=("${DEFAULT_REQUIRED_TAGS[@]}")

    log "Loaded policy from $POLICY_FILE"
else
    NAMESPACES=("${DEFAULT_NAMESPACES[@]}")
    REQUIRED_TAGS=("${DEFAULT_REQUIRED_TAGS[@]}")
    # Minimal built-in allowed-value policy, mirrors v1 defaults
    POLICY_JSON=$(cat <<'EOF'
{
  "allowed_values": {
    "Environment": ["PROD","NON-PROD","DEV","TEST","UAT"],
    "Purpose": ["APPLICATION","DATABASE","NETWORK","SECURITY","BACKUP","MONITORING","STORAGE"]
  }
}
EOF
)
    log "No --policy file supplied; using built-in default policy."
fi

TOTAL_REQUIRED_TAGS=${#REQUIRED_TAGS[@]}
if [ "$TOTAL_REQUIRED_TAGS" -eq 0 ]; then
    log "No required tags configured; nothing to validate." "ERROR"
    exit 1
fi

# Per-tag deduction so score is proportional to how many tags failed
DEDUCTION=$(awk -v n="$TOTAL_REQUIRED_TAGS" 'BEGIN{printf "%.4f", 100.0/n}')

validate_tag_value() {
    local tag_name="$1"
    local tag_value="$2"
    local allowed
    allowed=$(echo "$POLICY_JSON" | jq -r --arg k "$tag_name" '.allowed_values[$k]? // empty | .[]' 2>/dev/null)

    # No restricted list for this tag -> any non-empty value passes
    if [ -z "$allowed" ]; then
        return 0
    fi

    while IFS= read -r v; do
        [ "$v" = "$tag_value" ] && return 0
    done <<< "$allowed"

    return 1
}

# Build a normalized, comma-separated exclude list for jq's `inside`/`IN`
IFS=',' read -ra EXCLUDE_ARR <<< "${EXCLUDED_TYPES//' '/,}"
is_excluded_type() {
    local t="$1"
    for e in "${EXCLUDE_ARR[@]}"; do
        [ -n "$e" ] && [ "$e" = "$t" ] && return 0
    done
    return 1
}

# ============================================================
# RETRY WRAPPER FOR OCI CLI CALLS
# ============================================================

run_with_retry() {
    local attempt=1
    local output
    local rc
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        output=$("$@" 2>&1)
        rc=$?
        if [ $rc -eq 0 ]; then
            echo "$output"
            return 0
        fi
        log "Command failed (attempt $attempt/$MAX_RETRIES): $*" "WARN"
        vlog "Error output: $output"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
    done
    echo "$output"
    return $rc
}

# ============================================================
# HEADER
# ============================================================

log "============================================================"
log "OCI RESOURCE TAG GOVERNANCE & COMPLIANCE CHECKER v${SCRIPT_VERSION}"
log "============================================================"
log "Region        : $REGION"
log "Profile       : $PROFILE"
log "Scope         : ${COMPARTMENT_ID:-All searchable resources in tenancy}"
log "Namespaces    : ${NAMESPACES[*]}"
log "Required tags : ${REQUIRED_TAGS[*]}"
[ -n "$EXCLUDED_TYPES" ] && log "Excluded types: $EXCLUDED_TYPES"
log "Output dir    : $OUTPUT_DIR"
log "------------------------------------------------------------"

echo "Resource Type,Resource Name,Resource OCID,Compartment OCID,Compliance Score,Status,Missing Tags,Invalid Tags,Empty Tags" \
    > "$CSV_FILE"

# ============================================================
# BUILD QUERY
# ============================================================

if [ -n "$COMPARTMENT_ID" ]; then
    QUERY_TEXT="query all resources where compartmentId = '${COMPARTMENT_ID}'"
else
    QUERY_TEXT="query all resources"
fi

log "Query: $QUERY_TEXT"

# ============================================================
# RESOURCE SEARCH (with pagination)
# ============================================================

TMP_ITEMS_FILE=$(mktemp)
trap 'rm -f "$TMP_ITEMS_FILE"' EXIT

PAGE_TOKEN=""
PAGE_NUM=1
TOTAL_FETCHED=0

log "Starting resource search (page size: $PAGE_LIMIT)..."

while true; do
    if [ -n "$PAGE_TOKEN" ]; then
        RAW=$(run_with_retry oci search resource structured-search \
            --query-text "$QUERY_TEXT" \
            --region "$REGION" \
            --profile "$PROFILE" \
            --limit "$PAGE_LIMIT" \
            --page "$PAGE_TOKEN")
    else
        RAW=$(run_with_retry oci search resource structured-search \
            --query-text "$QUERY_TEXT" \
            --region "$REGION" \
            --profile "$PROFILE" \
            --limit "$PAGE_LIMIT")
    fi
    rc=$?

    if [ $rc -ne 0 ]; then
        log "OCI Resource Search failed on page $PAGE_NUM after $MAX_RETRIES attempts." "ERROR"
        log "$RAW" "ERROR"
        exit 1
    fi

    if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
        log "Received non-JSON response from OCI CLI on page $PAGE_NUM." "ERROR"
        exit 1
    fi

    PAGE_COUNT=$(echo "$RAW" | jq '.data.items | length')
    echo "$RAW" | jq -c '.data.items[]' >> "$TMP_ITEMS_FILE"
    TOTAL_FETCHED=$((TOTAL_FETCHED + PAGE_COUNT))

    vlog "Page $PAGE_NUM: fetched $PAGE_COUNT items (running total: $TOTAL_FETCHED)"

    PAGE_TOKEN=$(echo "$RAW" | jq -r '.opc-next-page // empty' 2>/dev/null)
    # Some CLI versions surface the token as top-level "next-page" header via --all;
    # fall back to stopping if we can't find one.
    if [ -z "$PAGE_TOKEN" ]; then
        break
    fi
    PAGE_NUM=$((PAGE_NUM + 1))
done

RESOURCE_COUNT="$TOTAL_FETCHED"

if [ "$RESOURCE_COUNT" -eq 0 ]; then
    log "No searchable resources were found."
    exit 0
fi

log "Resources discovered: $RESOURCE_COUNT"
log "------------------------------------------------------------"

# ============================================================
# COUNTERS
# ============================================================

TOTAL_RESOURCES=0
SKIPPED_RESOURCES=0
COMPLIANT_RESOURCES=0
WARNING_RESOURCES=0
NON_COMPLIANT_RESOURCES=0
TOTAL_MISSING_TAGS=0
TOTAL_INVALID_TAGS=0
TOTAL_EMPTY_TAGS=0
SCORE_SUM=0

# Per-resource-type breakdown, e.g. TYPE_COUNTS["Instance"]=42
declare -A TYPE_TOTAL
declare -A TYPE_COMPLIANT

# ============================================================
# PROCESS RESOURCES
# ============================================================

while IFS= read -r RESOURCE; do

    RESOURCE_TYPE=$(echo "$RESOURCE" | jq -r '.resourceType // "UNKNOWN"')
    RESOURCE_NAME=$(echo "$RESOURCE" | jq -r '.displayName // "N/A"')
    RESOURCE_ID=$(echo "$RESOURCE" | jq -r '.identifier // "N/A"')
    RESOURCE_COMPARTMENT=$(echo "$RESOURCE" | jq -r '.compartmentId // "N/A"')

    if is_excluded_type "$RESOURCE_TYPE"; then
        SKIPPED_RESOURCES=$((SKIPPED_RESOURCES + 1))
        vlog "Skipping excluded type: $RESOURCE_TYPE ($RESOURCE_NAME)"
        continue
    fi

    TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
    TYPE_TOTAL["$RESOURCE_TYPE"]=$(( ${TYPE_TOTAL["$RESOURCE_TYPE"]:-0} + 1 ))

    vlog "------------------------------------------------------------"
    vlog "Resource Type : $RESOURCE_TYPE"
    vlog "Resource Name : $RESOURCE_NAME"
    vlog "Resource ID   : $RESOURCE_ID"

    MISSING_TAGS=""
    INVALID_TAGS=""
    EMPTY_TAGS=""
    RESOURCE_ISSUES=0

    for TAG_NAME in "${REQUIRED_TAGS[@]}"; do

        TAG_VALUE=""
        FOUND_IN_NAMESPACE=""

        # Check each configured namespace until we find the tag
        for NS in "${NAMESPACES[@]}"; do
            V=$(echo "$RESOURCE" | jq -r --arg ns "$NS" --arg key "$TAG_NAME" \
                '.definedTags[$ns][$key] // empty')
            if [ -n "$V" ]; then
                TAG_VALUE="$V"
                FOUND_IN_NAMESPACE="$NS"
                break
            fi
        done

        if [ -z "$TAG_VALUE" ]; then
            vlog "MISSING TAG : $TAG_NAME"
            MISSING_TAGS="${MISSING_TAGS}${TAG_NAME};"
            TOTAL_MISSING_TAGS=$((TOTAL_MISSING_TAGS + 1))
            RESOURCE_ISSUES=$((RESOURCE_ISSUES + 1))
            continue
        fi

        if [ -z "$(echo "$TAG_VALUE" | xargs)" ]; then
            vlog "EMPTY TAG   : $TAG_NAME"
            EMPTY_TAGS="${EMPTY_TAGS}${TAG_NAME};"
            TOTAL_EMPTY_TAGS=$((TOTAL_EMPTY_TAGS + 1))
            RESOURCE_ISSUES=$((RESOURCE_ISSUES + 1))
            continue
        fi

        if validate_tag_value "$TAG_NAME" "$TAG_VALUE"; then
            vlog "PASS        : $TAG_NAME = $TAG_VALUE (ns: $FOUND_IN_NAMESPACE)"
        else
            vlog "INVALID TAG : $TAG_NAME = $TAG_VALUE"
            INVALID_TAGS="${INVALID_TAGS}${TAG_NAME};"
            TOTAL_INVALID_TAGS=$((TOTAL_INVALID_TAGS + 1))
            RESOURCE_ISSUES=$((RESOURCE_ISSUES + 1))
        fi
    done

    # --------------------------------------------------------
    # Proportional compliance score
    # --------------------------------------------------------
    SCORE=$(awk -v issues="$RESOURCE_ISSUES" -v ded="$DEDUCTION" \
        'BEGIN{s=100-(issues*ded); if(s<0) s=0; printf "%.0f", s}')

    if [ "$RESOURCE_ISSUES" -eq 0 ]; then
        STATUS="COMPLIANT"
        COMPLIANT_RESOURCES=$((COMPLIANT_RESOURCES + 1))
        TYPE_COMPLIANT["$RESOURCE_TYPE"]=$(( ${TYPE_COMPLIANT["$RESOURCE_TYPE"]:-0} + 1 ))
    elif [ "$SCORE" -ge 70 ]; then
        STATUS="WARNING"
        WARNING_RESOURCES=$((WARNING_RESOURCES + 1))
    else
        STATUS="NON_COMPLIANT"
        NON_COMPLIANT_RESOURCES=$((NON_COMPLIANT_RESOURCES + 1))
    fi

    SCORE_SUM=$((SCORE_SUM + SCORE))

    vlog "Score: $SCORE | Status: $STATUS"

    # Trim trailing semicolons for cleaner CSV
    MISSING_TAGS="${MISSING_TAGS%;}"
    INVALID_TAGS="${INVALID_TAGS%;}"
    EMPTY_TAGS="${EMPTY_TAGS%;}"

    echo "\"$RESOURCE_TYPE\",\"$RESOURCE_NAME\",\"$RESOURCE_ID\",\"$RESOURCE_COMPARTMENT\",\"$SCORE\",\"$STATUS\",\"$MISSING_TAGS\",\"$INVALID_TAGS\",\"$EMPTY_TAGS\"" \
        >> "$CSV_FILE"

    # Append a compact record for the JSON summary
    jq -n \
        --arg type "$RESOURCE_TYPE" \
        --arg name "$RESOURCE_NAME" \
        --arg id "$RESOURCE_ID" \
        --arg compartment "$RESOURCE_COMPARTMENT" \
        --argjson score "$SCORE" \
        --arg status "$STATUS" \
        --arg missing "$MISSING_TAGS" \
        --arg invalid "$INVALID_TAGS" \
        --arg empty "$EMPTY_TAGS" \
        '{resourceType:$type, resourceName:$name, resourceId:$id, compartmentId:$compartment,
          score:$score, status:$status,
          missingTags: ($missing | select(.!="") | split(";")) // [],
          invalidTags: ($invalid | select(.!="") | split(";")) // [],
          emptyTags: ($empty | select(.!="") | split(";")) // []}' \
        >> "${OUTPUT_DIR}/.resources_${TIMESTAMP}.jsonl"

done < "$TMP_ITEMS_FILE"

log ""
log "Processed: $TOTAL_RESOURCES  |  Skipped (excluded types): $SKIPPED_RESOURCES"
log "------------------------------------------------------------"

# ============================================================
# OVERALL COMPLIANCE
# ============================================================

if [ "$TOTAL_RESOURCES" -gt 0 ]; then
    OVERALL_SCORE=$(awk -v s="$SCORE_SUM" -v n="$TOTAL_RESOURCES" 'BEGIN{printf "%.1f", s/n}')
    COMPLIANT_PCT=$(awk -v c="$COMPLIANT_RESOURCES" -v n="$TOTAL_RESOURCES" 'BEGIN{printf "%.1f", (c/n)*100}')
else
    OVERALL_SCORE=0
    COMPLIANT_PCT=0
fi

if [ "$NON_COMPLIANT_RESOURCES" -gt 0 ]; then
    OVERALL_STATUS="NON_COMPLIANT"
elif [ "$WARNING_RESOURCES" -gt 0 ]; then
    OVERALL_STATUS="COMPLIANT_WITH_WARNINGS"
else
    OVERALL_STATUS="FULLY_COMPLIANT"
fi

# ============================================================
# FINAL LOG SUMMARY
# ============================================================

log "============================================================"
log "OCI TAG COMPLIANCE SUMMARY"
log "============================================================"
log "Total Resources Scanned   : $TOTAL_RESOURCES"
log "Skipped (excluded types)  : $SKIPPED_RESOURCES"
log "Compliant Resources       : $COMPLIANT_RESOURCES ($COMPLIANT_PCT%)"
log "Warning Resources         : $WARNING_RESOURCES"
log "Non-Compliant Resources   : $NON_COMPLIANT_RESOURCES"
log "Total Missing Tags        : $TOTAL_MISSING_TAGS"
log "Total Invalid Tags        : $TOTAL_INVALID_TAGS"
log "Total Empty Tags          : $TOTAL_EMPTY_TAGS"
log "Average Compliance Score  : $OVERALL_SCORE"
log "Overall Status            : $OVERALL_STATUS"
log "------------------------------------------------------------"
log "CSV Report  : $CSV_FILE"
log "JSON Summary: $JSON_FILE"
log "HTML Report : $HTML_FILE"
log "Log File    : $LOG_FILE"
log "============================================================"

# ============================================================
# BUILD PER-TYPE BREAKDOWN JSON
# ============================================================

TYPE_BREAKDOWN="[]"
for T in "${!TYPE_TOTAL[@]}"; do
    TOT=${TYPE_TOTAL[$T]}
    COMP=${TYPE_COMPLIANT[$T]:-0}
    TYPE_BREAKDOWN=$(echo "$TYPE_BREAKDOWN" | jq \
        --arg type "$T" --argjson total "$TOT" --argjson compliant "$COMP" \
        '. + [{resourceType:$type, total:$total, compliant:$compliant,
               compliantPct: (if $total>0 then (($compliant/$total)*100) else 0 end)}]')
done

# ============================================================
# WRITE JSON SUMMARY
# ============================================================

RESOURCES_JSON="[]"
if [ -f "${OUTPUT_DIR}/.resources_${TIMESTAMP}.jsonl" ]; then
    RESOURCES_JSON=$(jq -s '.' "${OUTPUT_DIR}/.resources_${TIMESTAMP}.jsonl")
    rm -f "${OUTPUT_DIR}/.resources_${TIMESTAMP}.jsonl"
fi

jq -n \
    --arg region "$REGION" \
    --arg compartment "$COMPARTMENT_ID" \
    --arg scanTime "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson total "$TOTAL_RESOURCES" \
    --argjson skipped "$SKIPPED_RESOURCES" \
    --argjson compliant "$COMPLIANT_RESOURCES" \
    --argjson warning "$WARNING_RESOURCES" \
    --argjson nonCompliant "$NON_COMPLIANT_RESOURCES" \
    --argjson missingTags "$TOTAL_MISSING_TAGS" \
    --argjson invalidTags "$TOTAL_INVALID_TAGS" \
    --argjson emptyTags "$TOTAL_EMPTY_TAGS" \
    --argjson avgScore "$OVERALL_SCORE" \
    --arg status "$OVERALL_STATUS" \
    --argjson typeBreakdown "$TYPE_BREAKDOWN" \
    --argjson resources "$RESOURCES_JSON" \
    '{
        region: $region,
        compartmentId: ($compartment | select(.!="")),
        scanTime: $scanTime,
        summary: {
            totalResources: $total,
            skippedResources: $skipped,
            compliantResources: $compliant,
            warningResources: $warning,
            nonCompliantResources: $nonCompliant,
            totalMissingTags: $missingTags,
            totalInvalidTags: $invalidTags,
            totalEmptyTags: $emptyTags,
            averageComplianceScore: $avgScore,
            overallStatus: $status
        },
        byResourceType: $typeBreakdown,
        resources: $resources
    }' > "$JSON_FILE"

# ============================================================
# WRITE SIMPLE HTML REPORT
# ============================================================

{
cat <<HTML_HEAD
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>OCI Tag Compliance Report - ${TIMESTAMP}</title>
<style>
  body { font-family: Arial, sans-serif; margin: 24px; color: #222; }
  h1 { font-size: 20px; }
  table { border-collapse: collapse; width: 100%; margin-top: 12px; }
  th, td { border: 1px solid #ddd; padding: 6px 10px; font-size: 13px; text-align: left; }
  th { background: #f4f4f4; }
  .COMPLIANT { color: #1a7f37; font-weight: bold; }
  .WARNING { color: #b58900; font-weight: bold; }
  .NON_COMPLIANT { color: #d1242f; font-weight: bold; }
  .summary-box { background: #fafafa; border: 1px solid #ddd; padding: 12px 16px; margin-bottom: 16px; }
</style>
</head>
<body>
<h1>OCI Resource Tag Compliance Report</h1>
<div class="summary-box">
  <strong>Region:</strong> ${REGION}<br>
  <strong>Scan time:</strong> $(date '+%Y-%m-%d %H:%M:%S')<br>
  <strong>Total resources:</strong> ${TOTAL_RESOURCES} (skipped: ${SKIPPED_RESOURCES})<br>
  <strong>Compliant:</strong> ${COMPLIANT_RESOURCES} &nbsp;
  <strong>Warning:</strong> ${WARNING_RESOURCES} &nbsp;
  <strong>Non-compliant:</strong> ${NON_COMPLIANT_RESOURCES}<br>
  <strong>Average score:</strong> ${OVERALL_SCORE}<br>
  <strong>Overall status:</strong> ${OVERALL_STATUS}
</div>
<table>
<tr>
  <th>Type</th><th>Name</th><th>Score</th><th>Status</th>
  <th>Missing</th><th>Invalid</th><th>Empty</th>
</tr>
HTML_HEAD

tail -n +2 "$CSV_FILE" | while IFS=, read -r type name id compartment score status missing invalid empty; do
    clean_status=$(echo "$status" | tr -d '"')
    echo "<tr><td>$(echo "$type" | tr -d '"')</td><td>$(echo "$name" | tr -d '"')</td><td>$(echo "$score" | tr -d '"')</td><td class=\"$clean_status\">$clean_status</td><td>$(echo "$missing" | tr -d '"')</td><td>$(echo "$invalid" | tr -d '"')</td><td>$(echo "$empty" | tr -d '"')</td></tr>"
done

cat <<HTML_TAIL
</table>
</body>
</html>
HTML_TAIL
} > "$HTML_FILE"

log "Report generation complete."

# ============================================================
# EXIT CODE
# ============================================================

EXIT_CODE=0

if awk -v s="$OVERALL_SCORE" -v t="$FAIL_BELOW_SCORE" 'BEGIN{exit !(s<t)}'; then
    log "Overall score ($OVERALL_SCORE) is below fail threshold ($FAIL_BELOW_SCORE)." "WARN"
    EXIT_CODE=1
fi

if [ "$STRICT_MODE" -eq 1 ] && [ "$NON_COMPLIANT_RESOURCES" -gt 0 ]; then
    log "Strict mode: $NON_COMPLIANT_RESOURCES non-compliant resource(s) found." "WARN"
    EXIT_CODE=1
fi

exit $EXIT_CODE
