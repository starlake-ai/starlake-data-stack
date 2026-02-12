#!/usr/bin/env bash
set -euo pipefail

# S3/SeaweedFS Regression Test Script for Starlake Helm Chart
#
# Run AFTER the cluster is deployed (after test-helm-chart.sh --seaweedfs completes).
# Tests the full lifecycle: auth -> project -> domain -> schema -> load -> verify
# with special emphasis on the 86-byte directory marker corruption bug.
#
# Usage:
#   ./test-s3-regression.sh                     # Run all tests (default)
#   ./test-s3-regression.sh --cleanup            # Delete test artifacts after run
#   ./test-s3-regression.sh --api-url http://x   # Custom API URL
#   ./test-s3-regression.sh --namespace ns        # Custom K8s namespace
#   ./test-s3-regression.sh --skip-s3             # Skip S3 direct checks (tests 8-9)
#   ./test-s3-regression.sh --verbose             # Show curl response bodies

# ============================================================
# Configuration
# ============================================================

API_URL="${API_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-starlake}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-seaweedfs}"
S3_SECRET_KEY="${S3_SECRET_KEY:-seaweedfs123}"
S3_BUCKET="${S3_BUCKET:-starlake}"
SEAWEEDFS_S3_PORT=18333   # Local port for S3 port-forward
SEAWEEDFS_FILER_PORT=18888 # Local port for Filer port-forward
CLEANUP_AFTER=false
SKIP_S3=false
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
SKIP=0

# Unique domain name to avoid collisions
DOMAIN_NAME="regtest_$(date +%s)"

# Cookie file for session
COOKIE_FILE=$(mktemp)

# Track port-forward PIDs for cleanup
PF_PIDS=()

# CSV file - search known locations
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CSV_FILE=""
for candidate in \
    "$PROJECT_ROOT/tpch001/datasets/stage/tpch/orders-001.csv" \
    "$SCRIPT_DIR/../tpch001/datasets/stage/tpch/orders-001.csv" \
    "./tpch001/datasets/stage/tpch/orders-001.csv"; do
    if [[ -f "$candidate" ]]; then
        CSV_FILE="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
        break
    fi
done

# ============================================================
# Argument parsing
# ============================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --cleanup)
            CLEANUP_AFTER=true
            shift
            ;;
        --api-url)
            API_URL="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --skip-s3)
            SKIP_S3=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --cleanup          Delete test domain after run"
            echo "  --api-url URL      API base URL (default: http://localhost:8080)"
            echo "  --namespace NS     Kubernetes namespace (default: starlake)"
            echo "  --skip-s3          Skip direct S3/SeaweedFS checks (tests 8-9)"
            echo "  --verbose, -v      Show curl response bodies"
            echo "  --help, -h         Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage."
            exit 1
            ;;
    esac
done

# ============================================================
# Helper functions
# ============================================================

pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    FAIL=$((FAIL + 1))
}

skip() {
    echo -e "  ${YELLOW}SKIP${NC}: $1"
    SKIP=$((SKIP + 1))
}

info() {
    echo -e "  ${BLUE}INFO${NC}: $1"
}

verbose_log() {
    if [[ "$VERBOSE" = true ]]; then
        echo -e "  ${BLUE}BODY${NC}: $1"
    fi
}

# Perform a curl request and capture HTTP code + body
# Usage: api_call METHOD PATH [EXTRA_CURL_ARGS...]
# Sets: HTTP_CODE, HTTP_BODY
api_call() {
    local method="$1"
    local path="$2"
    shift 2

    local url="${API_URL}${path}"
    local response_file
    response_file=$(mktemp)

    HTTP_CODE=$(curl -s -o "$response_file" -w "%{http_code}" \
        -X "$method" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        "$url" "$@" 2>/dev/null) || HTTP_CODE="000"

    HTTP_BODY=$(cat "$response_file" 2>/dev/null || echo "")
    rm -f "$response_file"

    verbose_log "$(echo "$HTTP_BODY" | head -c 500)"
}

cleanup_port_forwards() {
    for pid in "${PF_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    PF_PIDS=()
}

cleanup() {
    rm -f "$COOKIE_FILE"
    cleanup_port_forwards
}

trap cleanup EXIT

# ============================================================
# Banner
# ============================================================

echo ""
echo "================================================================"
echo "  S3/SeaweedFS Regression Tests - Starlake Helm Chart"
echo "================================================================"
echo ""
echo "  API URL:    $API_URL"
echo "  Namespace:  $NAMESPACE"
echo "  Domain:     $DOMAIN_NAME"
echo "  Cleanup:    $CLEANUP_AFTER"
echo "  Skip S3:    $SKIP_S3"
if [[ -n "$CSV_FILE" ]]; then
    echo "  CSV File:   $CSV_FILE"
else
    echo "  CSV File:   NOT FOUND (tests 5-6 will be skipped)"
fi
echo ""

# ============================================================
# Prerequisites
# ============================================================

echo "----------------------------------------------------------------"
echo "  Prerequisites"
echo "----------------------------------------------------------------"

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    fail "kubectl not found in PATH"
    echo "Cannot continue without kubectl."
    exit 1
fi
pass "kubectl available"

# Check cluster pods
POD_STATUS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
if [[ -z "$POD_STATUS" ]]; then
    fail "No pods found in namespace '$NAMESPACE'"
    echo "Deploy the cluster first: ./test-helm-chart.sh --seaweedfs"
    exit 1
fi

RUNNING_COUNT=$(echo "$POD_STATUS" | grep -c "Running" || true)
if [[ "$RUNNING_COUNT" -ge 4 ]]; then
    pass "Cluster running ($RUNNING_COUNT pods in Running state)"
else
    fail "Only $RUNNING_COUNT pods running (expected >= 4)"
    echo "$POD_STATUS"
    exit 1
fi

# Check API accessibility
API_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL}/api/v1/health" 2>/dev/null || echo "000")
if [[ "$API_HEALTH" = "200" ]]; then
    pass "API accessible at ${API_URL} (HTTP $API_HEALTH)"
else
    fail "API not accessible at ${API_URL} (HTTP $API_HEALTH)"
    echo "Ensure port-forward is running: kubectl port-forward svc/starlake-ui 8080:80 -n $NAMESPACE"
    exit 1
fi

# Check jq
if ! command -v jq &>/dev/null; then
    fail "jq not found in PATH (required for JSON parsing)"
    echo "Install with: brew install jq"
    exit 1
fi
pass "jq available"

echo ""

# ============================================================
# Test 1: Authentication
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 1: Authentication"
echo "----------------------------------------------------------------"

api_call POST "/api/v1/auth/basic/signin" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@localhost.local","password":"admin"}'

if [[ "$HTTP_CODE" = "200" ]]; then
    pass "Authentication successful (HTTP $HTTP_CODE)"

    # Extract user info if available
    USER_EMAIL=$(echo "$HTTP_BODY" | jq -r '.email // .user.email // empty' 2>/dev/null || echo "")
    if [[ -n "$USER_EMAIL" ]]; then
        info "Authenticated as: $USER_EMAIL"
    fi
else
    fail "Authentication failed (HTTP $HTTP_CODE)"
    verbose_log "$HTTP_BODY"
    echo "Cannot continue without authentication."
    exit 1
fi

echo ""

# ============================================================
# Test 2: Select S3 Project
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 2: Select S3 Project"
echo "----------------------------------------------------------------"

# List existing projects
api_call GET "/api/v1/projects"

PROJECT_ID=""
if [[ "$HTTP_CODE" = "200" ]]; then
    pass "Projects listed (HTTP $HTTP_CODE)"

    # Find an S3 project (look for s3a in root or any project)
    # Parse projects - try to find one with S3 storage
    PROJECT_COUNT=$(echo "$HTTP_BODY" | jq 'if type == "array" then length else 0 end' 2>/dev/null || echo "0")
    info "Found $PROJECT_COUNT project(s)"

    if [[ "$PROJECT_COUNT" -gt 0 ]]; then
        # Try to find an S3 project first (root contains s3a)
        S3_PROJECT_ID=$(echo "$HTTP_BODY" | jq -r '[.[] | select(.root != null and (.root | contains("s3a")))][0].id // empty' 2>/dev/null || echo "")

        if [[ -n "$S3_PROJECT_ID" ]]; then
            PROJECT_ID="$S3_PROJECT_ID"
            PROJECT_NAME=$(echo "$HTTP_BODY" | jq -r ".[] | select(.id == $PROJECT_ID) | .name" 2>/dev/null || echo "unknown")
            info "Selected S3 project: $PROJECT_NAME (id=$PROJECT_ID)"
        else
            # Fall back to the first project
            PROJECT_ID=$(echo "$HTTP_BODY" | jq -r '.[0].id // empty' 2>/dev/null || echo "")
            PROJECT_NAME=$(echo "$HTTP_BODY" | jq -r '.[0].name // "unknown"' 2>/dev/null || echo "unknown")
            info "No S3 project found, using first project: $PROJECT_NAME (id=$PROJECT_ID)"
        fi
    fi
else
    fail "Failed to list projects (HTTP $HTTP_CODE)"
fi

if [[ -n "$PROJECT_ID" ]]; then
    # Select the project (updates session cookie)
    api_call GET "/api/v1/projects/$PROJECT_ID"

    if [[ "$HTTP_CODE" = "200" ]]; then
        pass "Project selected: id=$PROJECT_ID"
    else
        fail "Failed to select project $PROJECT_ID (HTTP $HTTP_CODE)"
        echo "Some tests may fail without an active project."
    fi
else
    skip "No project available to select"
    echo "  Create an S3 project manually or redeploy with --seaweedfs."
fi

echo ""

# ============================================================
# Test 3: Create Domain
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 3: Create Domain"
echo "----------------------------------------------------------------"

api_call POST "/api/v1/load/false" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$DOMAIN_NAME\",\"tags\":[],\"comment\":\"S3 regression test domain\"}"

if [[ "$HTTP_CODE" = "200" ]]; then
    pass "Domain '$DOMAIN_NAME' created (HTTP $HTTP_CODE)"
else
    fail "Failed to create domain '$DOMAIN_NAME' (HTTP $HTTP_CODE)"
    verbose_log "$HTTP_BODY"
fi

# Verify domain appears in list
api_call GET "/api/v1/load/names"

if [[ "$HTTP_CODE" = "200" ]]; then
    if echo "$HTTP_BODY" | jq -e ".[] | select(. == \"$DOMAIN_NAME\")" &>/dev/null || \
       echo "$HTTP_BODY" | jq -e ".[] | select(.name == \"$DOMAIN_NAME\")" &>/dev/null || \
       echo "$HTTP_BODY" | grep -q "$DOMAIN_NAME"; then
        pass "Domain '$DOMAIN_NAME' visible in domain list"
    else
        fail "Domain '$DOMAIN_NAME' not found in domain list"
        verbose_log "$HTTP_BODY"
    fi
else
    fail "Failed to list domains (HTTP $HTTP_CODE)"
fi

echo ""

# ============================================================
# Test 4: Check Empty Domain (86-Byte Bug Test)
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 4: Empty Domain Check (86-byte bug detection)"
echo "----------------------------------------------------------------"

# Check file counts
api_call GET "/api/v1/schemas/files-count/$DOMAIN_NAME"

if [[ "$HTTP_CODE" = "200" ]]; then
    pass "File counts retrieved (HTTP $HTTP_CODE)"

    # Parse counts - handle both flat and nested formats
    STAGE_COUNT=$(echo "$HTTP_BODY" | jq '.stage // .stageCount // 0' 2>/dev/null || echo "-1")
    INCOMING_COUNT=$(echo "$HTTP_BODY" | jq '.incoming // .incomingCount // 0' 2>/dev/null || echo "-1")
    UNRESOLVED_COUNT=$(echo "$HTTP_BODY" | jq '.unresolved // .unresolvedCount // 0' 2>/dev/null || echo "-1")
    INGESTING_COUNT=$(echo "$HTTP_BODY" | jq '.ingesting // .ingestingCount // 0' 2>/dev/null || echo "-1")
    ARCHIVE_COUNT=$(echo "$HTTP_BODY" | jq '.archive // .archiveCount // 0' 2>/dev/null || echo "-1")

    info "Counts - stage=$STAGE_COUNT incoming=$INCOMING_COUNT unresolved=$UNRESOLVED_COUNT ingesting=$INGESTING_COUNT archive=$ARCHIVE_COUNT"

    ALL_ZERO=true
    for count_name in STAGE_COUNT INCOMING_COUNT UNRESOLVED_COUNT INGESTING_COUNT ARCHIVE_COUNT; do
        count_val="${!count_name}"
        if [[ "$count_val" != "0" && "$count_val" != "-1" && "$count_val" != "null" ]]; then
            ALL_ZERO=false
        fi
    done

    if [[ "$ALL_ZERO" = true ]]; then
        pass "All file counts are 0 for empty domain"
    else
        fail "Non-zero file counts in empty domain (possible 86-byte bug)"
        verbose_log "$HTTP_BODY"
    fi
else
    fail "Failed to get file counts (HTTP $HTTP_CODE)"
fi

# Check stage file listing
api_call GET "/api/v1/schemas/files/$DOMAIN_NAME?type=stage"

if [[ "$HTTP_CODE" = "200" ]]; then
    FILE_LIST_LENGTH=$(echo "$HTTP_BODY" | jq 'if type == "array" then length else -1 end' 2>/dev/null || echo "-1")

    if [[ "$FILE_LIST_LENGTH" = "0" ]]; then
        pass "Stage file list is empty (no phantom files)"
    elif [[ "$FILE_LIST_LENGTH" = "-1" ]]; then
        # Might be an empty string or non-array response
        if [[ "$HTTP_BODY" = "[]" || -z "$HTTP_BODY" ]]; then
            pass "Stage file list is empty"
        else
            fail "Unexpected stage file list format"
            verbose_log "$HTTP_BODY"
        fi
    else
        # Check if any file has 86 bytes (the bug signature)
        HAS_86_BYTE=$(echo "$HTTP_BODY" | jq '[.[] | select(.fileSizeInBytes == 86 or .size == 86)] | length' 2>/dev/null || echo "0")
        if [[ "$HAS_86_BYTE" != "0" ]]; then
            fail "CRITICAL: 86-byte phantom file detected in stage (chunked encoding corruption bug)"
            verbose_log "$HTTP_BODY"
        else
            fail "Stage file list is not empty ($FILE_LIST_LENGTH files found in empty domain)"
            verbose_log "$HTTP_BODY"
        fi
    fi
else
    fail "Failed to list stage files (HTTP $HTTP_CODE)"
fi

echo ""

# ============================================================
# Test 5: Infer Schema and Create Table
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 5: Infer Schema and Create Table"
echo "----------------------------------------------------------------"

if [[ -z "$CSV_FILE" ]]; then
    skip "CSV file not found - cannot infer schema"
    skip "CSV file not found - cannot create table"
    SCHEMA_CREATED=false
else
    SCHEMA_CREATED=false

    # Infer schema from CSV (raw body, NOT multipart)
    api_call POST "/api/v1/schemas/infer-schema-attach?domain=$DOMAIN_NAME&schema=orders&pattern=orders-.*.csv&comment=orders&header=true&filename=orders-001.csv&variant=false" \
        -H "Content-Type: text/csv" \
        --data-binary "@$CSV_FILE"

    if [[ "$HTTP_CODE" = "200" ]]; then
        pass "Schema inferred from CSV (HTTP $HTTP_CODE)"

        # Check attribute count
        ATTR_COUNT=$(echo "$HTTP_BODY" | jq '.attributes | length' 2>/dev/null || echo "0")
        if [[ "$ATTR_COUNT" -eq 9 ]]; then
            pass "Schema has 9 attributes (correct for orders table)"
        elif [[ "$ATTR_COUNT" -gt 0 ]]; then
            info "Schema has $ATTR_COUNT attributes (expected 9)"
            pass "Schema has attributes ($ATTR_COUNT found)"
        else
            fail "Schema has no attributes"
            verbose_log "$HTTP_BODY"
        fi

        # Create the table using the inferred schema
        # The infer-schema-attach endpoint returns the schema body we need to POST
        api_call POST "/api/v1/schemas/$DOMAIN_NAME/false/orders" \
            -H "Content-Type: application/json" \
            -d "$HTTP_BODY"

        if [[ "$HTTP_CODE" = "200" ]]; then
            pass "Table 'orders' created in domain '$DOMAIN_NAME'"
            SCHEMA_CREATED=true
        else
            fail "Failed to create table 'orders' (HTTP $HTTP_CODE)"
            verbose_log "$HTTP_BODY"
        fi
    else
        fail "Schema inference failed (HTTP $HTTP_CODE)"
        verbose_log "$HTTP_BODY"
    fi
fi

echo ""

# ============================================================
# Test 6: Load Data
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 6: Load Data"
echo "----------------------------------------------------------------"

DATA_LOADED=false

if [[ -z "$CSV_FILE" ]]; then
    skip "CSV file not found - cannot load data"
elif [[ "$SCHEMA_CREATED" = false ]]; then
    skip "Table not created - cannot load data"
else
    # Load file via multipart upload
    api_call POST "/api/v1/schemas/$DOMAIN_NAME/orders/false/false/sl_none/load" \
        -F "file=@$CSV_FILE;type=text/csv"

    if [[ "$HTTP_CODE" = "200" ]]; then
        pass "Data loaded (HTTP $HTTP_CODE)"

        # Check accepted count
        ACCEPTED=$(echo "$HTTP_BODY" | jq '.acceptedCount // .accepted // -1' 2>/dev/null || echo "-1")
        REJECTED=$(echo "$HTTP_BODY" | jq '.rejectedCount // .rejected // 0' 2>/dev/null || echo "0")

        if [[ "$ACCEPTED" -gt 0 ]]; then
            pass "Load accepted $ACCEPTED rows (rejected: $REJECTED)"
            DATA_LOADED=true
        elif [[ "$ACCEPTED" = "-1" ]]; then
            info "Could not parse acceptedCount from response"
            verbose_log "$HTTP_BODY"
            # Treat as loaded since HTTP 200
            DATA_LOADED=true
        else
            fail "Load accepted 0 rows"
            verbose_log "$HTTP_BODY"
        fi
    else
        fail "Data load failed (HTTP $HTTP_CODE)"
        verbose_log "$HTTP_BODY"
    fi
fi

echo ""

# ============================================================
# Test 7: Verify File Areas After Load
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 7: Verify File Areas After Load"
echo "----------------------------------------------------------------"

if [[ "$DATA_LOADED" = false ]]; then
    skip "Data not loaded - cannot verify file areas"
    skip "Data not loaded - cannot verify archive"
    skip "Data not loaded - cannot check for 86-byte files"
else
    # Wait a moment for file movement to complete
    info "Waiting 3 seconds for file processing..."
    sleep 3

    # Check file counts after load
    api_call GET "/api/v1/schemas/files-count/$DOMAIN_NAME"

    if [[ "$HTTP_CODE" = "200" ]]; then
        STAGE_COUNT=$(echo "$HTTP_BODY" | jq '.stage // .stageCount // 0' 2>/dev/null || echo "0")
        INGESTING_COUNT=$(echo "$HTTP_BODY" | jq '.ingesting // .ingestingCount // 0' 2>/dev/null || echo "0")
        UNRESOLVED_COUNT=$(echo "$HTTP_BODY" | jq '.unresolved // .unresolvedCount // 0' 2>/dev/null || echo "0")
        ARCHIVE_COUNT=$(echo "$HTTP_BODY" | jq '.archive // .archiveCount // 0' 2>/dev/null || echo "0")

        info "Post-load counts - stage=$STAGE_COUNT ingesting=$INGESTING_COUNT unresolved=$UNRESOLVED_COUNT archive=$ARCHIVE_COUNT"

        if [[ "$ARCHIVE_COUNT" -ge 1 ]]; then
            pass "Archive has $ARCHIVE_COUNT file(s) after load"
        else
            fail "Archive has 0 files after load (expected >= 1)"
        fi

        if [[ "$STAGE_COUNT" = "0" ]]; then
            pass "Stage is empty after load (file moved correctly)"
        else
            info "Stage has $STAGE_COUNT files (may still be processing)"
        fi

        if [[ "$INGESTING_COUNT" = "0" ]]; then
            pass "Ingesting is empty after load (no stuck files)"
        else
            info "Ingesting has $INGESTING_COUNT files (may still be processing)"
        fi

        if [[ "$UNRESOLVED_COUNT" = "0" ]]; then
            pass "Unresolved is empty (no rejected files)"
        else
            fail "Unresolved has $UNRESOLVED_COUNT files (data quality issue?)"
        fi
    else
        fail "Failed to get post-load file counts (HTTP $HTTP_CODE)"
    fi

    # Check archive file listing for 86-byte bug
    api_call GET "/api/v1/schemas/files/$DOMAIN_NAME?type=archive"

    if [[ "$HTTP_CODE" = "200" ]]; then
        ARCHIVE_FILES=$(echo "$HTTP_BODY" | jq 'length' 2>/dev/null || echo "0")

        if [[ "$ARCHIVE_FILES" -ge 1 ]]; then
            # Check for the presence of orders-001.csv
            HAS_ORDERS=$(echo "$HTTP_BODY" | jq '[.[] | select(.name != null and (.name | contains("orders")))] | length' 2>/dev/null || echo "0")
            if [[ "$HAS_ORDERS" -ge 1 ]]; then
                pass "Archive contains orders file(s)"
            else
                info "Archive has files but none matching 'orders'"
                verbose_log "$HTTP_BODY"
            fi

            # Check file sizes - no file should be exactly 86 bytes
            FILES_86_BYTES=$(echo "$HTTP_BODY" | jq '[.[] | select(.fileSizeInBytes == 86 or .size == 86)] | length' 2>/dev/null || echo "0")
            if [[ "$FILES_86_BYTES" = "0" ]]; then
                pass "No 86-byte files in archive (chunked encoding bug NOT present)"
            else
                fail "CRITICAL: Found $FILES_86_BYTES file(s) with exactly 86 bytes in archive (chunked encoding corruption)"
                echo "$HTTP_BODY" | jq '.[] | select(.fileSizeInBytes == 86 or .size == 86)' 2>/dev/null || true
            fi

            # Check that archived file is reasonably sized (orders-001.csv is ~164KB)
            LARGE_FILES=$(echo "$HTTP_BODY" | jq '[.[] | select((.fileSizeInBytes // .size // 0) > 1000)] | length' 2>/dev/null || echo "0")
            if [[ "$LARGE_FILES" -ge 1 ]]; then
                pass "Archive contains files > 1KB (data integrity OK)"
            else
                fail "No files > 1KB in archive (possible data corruption)"
                verbose_log "$HTTP_BODY"
            fi
        else
            fail "No files in archive listing"
        fi
    else
        fail "Failed to list archive files (HTTP $HTTP_CODE)"
    fi
fi

echo ""

# ============================================================
# Test 8: Verify S3 Directory Markers
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 8: S3 Directory Markers (chunked encoding check)"
echo "----------------------------------------------------------------"

if [[ "$SKIP_S3" = true ]]; then
    skip "S3 checks skipped (--skip-s3)"
elif ! command -v aws &>/dev/null; then
    skip "aws CLI not found (install with: brew install awscli)"
else
    # Port-forward SeaweedFS S3 API
    info "Setting up port-forward to SeaweedFS S3 (localhost:$SEAWEEDFS_S3_PORT)..."

    # Check if SeaweedFS service exists
    SEAWEEDFS_SVC=$(kubectl get svc starlake-seaweedfs -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
    if [[ -z "$SEAWEEDFS_SVC" ]]; then
        skip "SeaweedFS service not found in namespace '$NAMESPACE'"
    else
        kubectl port-forward svc/starlake-seaweedfs "$SEAWEEDFS_S3_PORT":8333 -n "$NAMESPACE" >/dev/null 2>&1 &
        S3_PF_PID=$!
        PF_PIDS+=("$S3_PF_PID")
        sleep 3

        # Verify port-forward is alive
        if ! kill -0 "$S3_PF_PID" 2>/dev/null; then
            fail "Port-forward to SeaweedFS S3 failed (port $SEAWEEDFS_S3_PORT may be in use)"
        else
            pass "SeaweedFS S3 port-forward active on localhost:$SEAWEEDFS_S3_PORT"

            # Determine the project root prefix in S3
            # Projects are stored under a path like: <project_name>/datasets/...
            # We need to find what prefix the current project uses
            S3_ENDPOINT="http://localhost:$SEAWEEDFS_S3_PORT"
            export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
            export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

            # List bucket contents to find the project prefix
            BUCKET_CONTENTS=$(aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/" --no-sign-request 2>/dev/null || \
                              aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/" 2>/dev/null || echo "")

            if [[ -n "$BUCKET_CONTENTS" ]]; then
                pass "S3 bucket '$S3_BUCKET' accessible"
                verbose_log "$BUCKET_CONTENTS"
            else
                info "Could not list S3 bucket (may require specific prefix)"
            fi

            # Check directory markers for the test domain
            # Directory markers are objects with the same name as the "directory"
            # In S3, directories are virtual - they should NOT exist as objects,
            # or if they do, they should have ContentLength == 0 (not 86)
            MARKER_DIRS=("stage/$DOMAIN_NAME" "ingesting/$DOMAIN_NAME" "archive/$DOMAIN_NAME")
            MARKER_BUG_FOUND=false

            # Try common prefixes
            PREFIXES=("" "datasets/")

            # Also try to find project-specific prefix from the project info
            if [[ -n "$PROJECT_ID" ]]; then
                PREFIXES+=("${PROJECT_ID}/datasets/" "${PROJECT_NAME}/datasets/")
            fi

            for prefix in "${PREFIXES[@]}"; do
                for marker_dir in "${MARKER_DIRS[@]}"; do
                    FULL_KEY="${prefix}${marker_dir}"

                    HEAD_OUTPUT=$(aws --endpoint-url "$S3_ENDPOINT" \
                        s3api head-object \
                        --bucket "$S3_BUCKET" \
                        --key "$FULL_KEY" 2>/dev/null || echo "NOT_FOUND")

                    if [[ "$HEAD_OUTPUT" = "NOT_FOUND" ]]; then
                        # Object doesn't exist - this is fine (preferred behavior)
                        continue
                    fi

                    CONTENT_LENGTH=$(echo "$HEAD_OUTPUT" | jq -r '.ContentLength // 0' 2>/dev/null || echo "0")

                    if [[ "$CONTENT_LENGTH" = "86" ]]; then
                        fail "CRITICAL: Directory marker '$FULL_KEY' has ContentLength=86 (chunked encoding corruption)"
                        MARKER_BUG_FOUND=true
                    elif [[ "$CONTENT_LENGTH" = "0" ]]; then
                        info "Directory marker '$FULL_KEY' exists with ContentLength=0 (acceptable)"
                    else
                        info "Object '$FULL_KEY' has ContentLength=$CONTENT_LENGTH"
                    fi
                done
            done

            if [[ "$MARKER_BUG_FOUND" = false ]]; then
                pass "No 86-byte directory markers found (chunked encoding bug NOT present)"
            fi

            unset AWS_ACCESS_KEY_ID
            unset AWS_SECRET_ACCESS_KEY
        fi
    fi
fi

echo ""

# ============================================================
# Test 9: SeaweedFS Filer Accessibility
# ============================================================

echo "----------------------------------------------------------------"
echo "  Test 9: SeaweedFS Filer Accessibility"
echo "----------------------------------------------------------------"

if [[ "$SKIP_S3" = true ]]; then
    skip "S3 checks skipped (--skip-s3)"
else
    SEAWEEDFS_SVC=$(kubectl get svc starlake-seaweedfs -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
    if [[ -z "$SEAWEEDFS_SVC" ]]; then
        skip "SeaweedFS service not found in namespace '$NAMESPACE'"
    else
        info "Setting up port-forward to SeaweedFS Filer (localhost:$SEAWEEDFS_FILER_PORT)..."
        kubectl port-forward svc/starlake-seaweedfs "$SEAWEEDFS_FILER_PORT":8888 -n "$NAMESPACE" >/dev/null 2>&1 &
        FILER_PF_PID=$!
        PF_PIDS+=("$FILER_PF_PID")
        sleep 3

        if ! kill -0 "$FILER_PF_PID" 2>/dev/null; then
            fail "Port-forward to SeaweedFS Filer failed (port $SEAWEEDFS_FILER_PORT may be in use)"
        else
            # Check Filer UI root
            FILER_ROOT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$SEAWEEDFS_FILER_PORT/" 2>/dev/null || echo "000")
            if [[ "$FILER_ROOT_CODE" = "200" ]]; then
                pass "SeaweedFS Filer UI accessible (HTTP $FILER_ROOT_CODE)"
            else
                fail "SeaweedFS Filer UI not accessible (HTTP $FILER_ROOT_CODE)"
            fi

            # Check Filer for the bucket path
            FILER_BUCKET_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$SEAWEEDFS_FILER_PORT/buckets/$S3_BUCKET/" 2>/dev/null || echo "000")
            if [[ "$FILER_BUCKET_CODE" = "200" ]]; then
                pass "Filer bucket path '/buckets/$S3_BUCKET/' accessible (HTTP $FILER_BUCKET_CODE)"
            else
                info "Filer bucket path HTTP $FILER_BUCKET_CODE (bucket may use different path)"
            fi

            # Try to fetch the archive directory via Filer JSON API
            if [[ "$DATA_LOADED" = true ]]; then
                # SeaweedFS Filer provides JSON listing with ?pretty=y
                FILER_ARCHIVE_BODY=$(curl -s "http://localhost:$SEAWEEDFS_FILER_PORT/buckets/$S3_BUCKET/" \
                    -H "Accept: application/json" 2>/dev/null || echo "")

                if [[ -n "$FILER_ARCHIVE_BODY" ]] && echo "$FILER_ARCHIVE_BODY" | jq '.' &>/dev/null; then
                    FILER_ENTRIES=$(echo "$FILER_ARCHIVE_BODY" | jq '.Entries // .entries // [] | length' 2>/dev/null || echo "0")
                    if [[ "$FILER_ENTRIES" -gt 0 ]]; then
                        pass "Filer shows $FILER_ENTRIES entries in bucket root"
                    else
                        info "Filer shows 0 entries (files may be in subdirectories)"
                    fi
                else
                    info "Filer response is not JSON (HTML UI returned instead)"
                    # The HTML UI being returned is fine - it means the Filer is working
                    if echo "$FILER_ARCHIVE_BODY" | grep -qi "html\|SeaweedFS" 2>/dev/null; then
                        pass "Filer returns HTML UI (service is functional)"
                    fi
                fi
            fi
        fi
    fi
fi

echo ""

# ============================================================
# Cleanup (optional)
# ============================================================

if [[ "$CLEANUP_AFTER" = true ]]; then
    echo "----------------------------------------------------------------"
    echo "  Cleanup"
    echo "----------------------------------------------------------------"

    # Delete the test domain
    api_call POST "/api/v1/load/$DOMAIN_NAME/delete" \
        -H "Content-Type: application/json"

    # Try alternative delete endpoint if first fails
    if [[ "$HTTP_CODE" != "200" ]]; then
        api_call DELETE "/api/v1/load/$DOMAIN_NAME"
    fi

    if [[ "$HTTP_CODE" = "200" ]]; then
        pass "Test domain '$DOMAIN_NAME' deleted"
    else
        info "Could not auto-delete domain '$DOMAIN_NAME' (HTTP $HTTP_CODE)"
        info "Delete manually via the UI or API."
    fi

    echo ""
fi

# ============================================================
# Summary
# ============================================================

echo "================================================================"
echo "  Results"
echo "================================================================"
echo ""
echo -e "  ${GREEN}PASSED${NC}: $PASS"
echo -e "  ${RED}FAILED${NC}: $FAIL"
echo -e "  ${YELLOW}SKIPPED${NC}: $SKIP"
echo ""

TOTAL=$((PASS + FAIL + SKIP))
echo "  Total: $TOTAL tests"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}REGRESSION DETECTED${NC} - $FAIL test(s) failed"
    echo ""
    echo "  Hints:"
    echo "    - 86-byte bug: Check Transfer-Encoding handling in UI S3 proxy"
    echo "    - Empty domain phantom files: S3 directory marker created as object"
    echo "    - Load failures: Verify SeaweedFS S3 API is configured correctly"
    echo "    - Run with --verbose for detailed response bodies"
    echo ""
    exit 1
else
    echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    echo ""
    if [[ "$CLEANUP_AFTER" = false ]]; then
        echo "  Test domain '$DOMAIN_NAME' was NOT cleaned up."
        echo "  Run with --cleanup to auto-delete, or delete manually."
    fi
    echo ""
    exit 0
fi
