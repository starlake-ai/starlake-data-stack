#!/usr/bin/env bash
# Starlake CLI wrapper for Kubernetes - creates K8s Jobs for task execution
# This script is used by Dockerfile_airflow_k8s to offload starlake commands to separate K8s Jobs
#
# Required environment variables:
#   STARLAKE_NAMESPACE - Kubernetes namespace for Jobs (default: from service account)
#   SL_ROOT - Starlake root directory (default: /projects)
#
# Optional environment variables:
#   JOB_TEMPLATE_PATH - Path to job template YAML (default: /etc/starlake/job-template.yaml)
#   STARLAKE_IMAGE - Docker image for Jobs (default: same as current pod)
#   STARLAKE_IMAGE_TAG - Image tag (default: latest)
#
# The script requires:
#   - kubectl in PATH or common locations
#   - ServiceAccount token mounted (for in-cluster auth)
#   - Job template YAML at JOB_TEMPLATE_PATH

set -e

# Check if at least one argument is passed
if [ "$#" -eq 0 ]; then
  echo "No arguments provided. Usage: starlake <command> [args...]"
  exit 1
fi

# Handle arguments from starlake-airflow:
# - --options may contain both:
#     - SL_* variables (SL_ROOT, SL_DATASETS, etc.) -> export as env vars
#     - Other options (date_min, date_max, etc.) -> pass to starlake --options
# - --scheduledDate is a native starlake option -> pass as-is
old_ifs="$IFS"
raw_options=""      # Raw --options value from starlake-airflow
command=""
arguments=()

# First argument is always the command
command="$1"
shift

# Parse remaining arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--options) raw_options="$2"; shift 2 ;;
        *) arguments+=("$1"); shift ;;
    esac
done

# Separate SL_* env vars from starlake options
env_vars=()         # SL_* variables to export
starlake_options=() # Other options to pass to starlake --options

if [ -n "$raw_options" ]; then
    IFS=',' read -ra opt_array <<< "$raw_options"
    for opt in "${opt_array[@]}"; do
        name="${opt%%=*}"
        value="${opt#*=}"
        # Remove surrounding quotes (both single and double) from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        if [[ "$name" == SL_* ]]; then
            # SL_* variables -> export as environment variables
            export "$name=$value"
            env_vars+=("$name=$value")
        else
            # Other options -> pass to starlake --options
            starlake_options+=("$name=$value")
        fi
    done
    IFS="$old_ifs"
fi

# Log what we're doing
if [ ${#env_vars[@]} -gt 0 ]; then
    echo "=== Exported env vars: ${env_vars[*]} ==="
fi
if [ ${#starlake_options[@]} -gt 0 ]; then
    echo "=== Starlake options: ${starlake_options[*]} ==="
fi

# Reconstruct full args array with command first
# --scheduledDate and other native options are already in arguments[]
# Add --options only if we have starlake options to pass
if [ ${#starlake_options[@]} -gt 0 ]; then
    # Join starlake_options with commas
    options_str=$(IFS=','; echo "${starlake_options[*]}")
    FULL_ARGS=("$command" "--options" "$options_str" "${arguments[@]}")
else
    FULL_ARGS=("$command" "${arguments[@]}")
fi

# Configuration from environment
JOB_TEMPLATE="${JOB_TEMPLATE_PATH:-/etc/starlake/job-template.yaml}"
NAMESPACE="${STARLAKE_NAMESPACE:-default}"

# Try to get namespace from service account if not set
if [ "$NAMESPACE" = "default" ] && [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
  NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
fi

# Find kubectl binary
KUBECTL=""
for loc in "/shared-tools/bin/kubectl" "/usr/local/bin/kubectl" "/usr/bin/kubectl" "kubectl"; do
  if command -v "$loc" >/dev/null 2>&1 || [ -x "$loc" ]; then
    KUBECTL="$loc"
    break
  fi
done

if [ -z "$KUBECTL" ]; then
  echo "ERROR: kubectl not found. Searched: /shared-tools/bin/kubectl, /usr/local/bin/kubectl, /usr/bin/kubectl, PATH"
  exit 1
fi

# Configure kubectl for in-cluster authentication
# Use kubernetes.default.svc as fallback when env vars not available (e.g., in Airflow subprocess)
if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
  KUBE_API_SERVER="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
else
  KUBE_API_SERVER="https://kubernetes.default.svc:443"
fi

# Check if service account token exists
if [ ! -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  echo "ERROR: ServiceAccount token not found at /var/run/secrets/kubernetes.io/serviceaccount/token"
  echo "Make sure automountServiceAccountToken is enabled for this pod"
  exit 1
fi

KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBE_CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

# kubectl wrapper function with in-cluster config
kubectl_cmd() {
  "$KUBECTL" --server="$KUBE_API_SERVER" --token="$KUBE_TOKEN" --certificate-authority="$KUBE_CA_CERT" "$@"
}

# Check if job template exists
if [ ! -f "$JOB_TEMPLATE" ]; then
  echo "ERROR: Job template not found at $JOB_TEMPLATE"
  echo "Set JOB_TEMPLATE_PATH environment variable to specify a different location"
  exit 1
fi

# Generate unique job name based on command and timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RANDOM_SUFFIX=$(printf '%04x' $RANDOM)
JOB_NAME="sl-${command}-${TIMESTAMP}-${RANDOM_SUFFIX}"
# Kubernetes job names must be lowercase and max 63 chars
JOB_NAME=$(echo "$JOB_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63)

# Build args array for YAML (JSON array format)
# Proper JSON escaping to prevent command injection
ARGS_JSON="["
FIRST=true
for arg in "${FULL_ARGS[@]}"; do
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    ARGS_JSON="${ARGS_JSON}, "
  fi
  # Properly escape for JSON: backslashes first, then quotes, tabs, newlines
  ESCAPED_ARG=$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n' ' ')
  ARGS_JSON="${ARGS_JSON}\"${ESCAPED_ARG}\""
done
ARGS_JSON="${ARGS_JSON}]"

# Create temporary job manifest
TEMP_JOB=$(mktemp /tmp/starlake-job-XXXXXX.yaml)
trap "rm -f $TEMP_JOB" EXIT

# Build env vars YAML (12 spaces indent to match template)
ENV_FILE=$(mktemp /tmp/starlake-env-XXXXXX.yaml)
trap "rm -f $TEMP_JOB $ENV_FILE" EXIT

for var in $(env | grep -E "^SL_" | grep -v "^SL_ROOT=" | cut -d= -f1); do
  value="${!var}"
  # Escape for YAML string: backslashes first, then double quotes
  escaped_value=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
  # 12 spaces for - name:, 14 spaces for value: (matching template)
  echo "            - name: ${var}" >> "$ENV_FILE"
  echo "              value: \"${escaped_value}\"" >> "$ENV_FILE"
done

# Read template and create job manifest
# Replace simple placeholders
sed -e "s|__JOB_NAME__|${JOB_NAME}|g" \
    -e "s|__STARLAKE_ARGS__|${ARGS_JSON}|g" \
    -e "s|__SL_ROOT__|${SL_ROOT:-/projects}|g" \
    "$JOB_TEMPLATE" > "$TEMP_JOB"

# Replace __ENV_VARS__ with actual env vars from file
if [ -s "$ENV_FILE" ]; then
  # Use awk to replace __ENV_VARS__ with file contents
  awk -v envfile="$ENV_FILE" '
    /__ENV_VARS__/ {
      while ((getline line < envfile) > 0) print line
      close(envfile)
      next
    }
    {print}
  ' "$TEMP_JOB" > "${TEMP_JOB}.tmp" && mv "${TEMP_JOB}.tmp" "$TEMP_JOB"
else
  # No env vars, just remove the placeholder
  sed -i '/__ENV_VARS__/d' "$TEMP_JOB" 2>/dev/null || sed -i '' '/__ENV_VARS__/d' "$TEMP_JOB"
fi

echo "=== Creating Kubernetes Job: ${JOB_NAME} ==="
echo "Command: starlake ${FULL_ARGS[*]}"
echo "Namespace: ${NAMESPACE}"
echo "SL_ROOT: ${SL_ROOT:-/projects}"

# Create the job (--validate=false to avoid openapi download issues)
kubectl_cmd apply -f "$TEMP_JOB" -n "$NAMESPACE" --validate=false

# Wait for pod to be created and get its name
echo "=== Waiting for pod to start ==="
POD_NAME=""
for i in $(seq 1 60); do
  POD_NAME=$(kubectl_cmd get pods -n "$NAMESPACE" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$POD_NAME" ]; then
    POD_STATUS=$(kubectl_cmd get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "$POD_STATUS" != "Pending" ]; then
      break
    fi
  fi
  sleep 2
done

if [ -z "$POD_NAME" ]; then
  echo "ERROR: Pod not created after 120 seconds"
  kubectl_cmd get jobs -n "$NAMESPACE" -l "job-name=${JOB_NAME}" -o yaml
  exit 1
fi

echo "=== Pod ${POD_NAME} started, streaming logs ==="

# Stream logs (follow until completion)
kubectl_cmd logs -f "$POD_NAME" -n "$NAMESPACE" -c starlake 2>/dev/null || true

# IMPORTANT: Capture exit code IMMEDIATELY after logs complete
# kubectl logs -f finishes when the container terminates, so this is the best time to capture
# We need to do this before TTL can delete the job/pod
echo "=== Checking job completion status ==="

# Small delay to allow Kubernetes to update pod status
sleep 1

# Try to get exit code from pod immediately
IMMEDIATE_EXIT_CODE=$(kubectl_cmd get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="starlake")].state.terminated.exitCode}' 2>/dev/null || echo "")

if [ -n "$IMMEDIATE_EXIT_CODE" ]; then
  if [ "$IMMEDIATE_EXIT_CODE" = "0" ]; then
    echo "=== Job completed successfully (exit code: 0) ==="
    exit 0
  else
    echo "=== Job failed (exit code: $IMMEDIATE_EXIT_CODE) ==="
    exit "$IMMEDIATE_EXIT_CODE"
  fi
fi

# If we couldn't get the exit code immediately, fall back to polling
# This handles cases where the container hasn't fully terminated yet
echo "=== Waiting for job completion (polling) ==="
MAX_WAIT=3600  # 1 hour max
POLL_INTERVAL=5
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
  # Check if job still exists
  JOB_EXISTS=$(kubectl_cmd get job "${JOB_NAME}" -n "$NAMESPACE" -o name 2>/dev/null || echo "")

  if [ -z "$JOB_EXISTS" ]; then
    # Job was deleted (by TTL after completion) - check pod exit code
    echo "Job was deleted (likely completed and cleaned up by TTL)"
    EXIT_CODE=$(kubectl_cmd get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")

    if [ -z "$EXIT_CODE" ]; then
      # Pod also deleted, assume success if we got here (logs were streamed)
      echo "=== Job completed (pod also cleaned up) ==="
      exit 0
    elif [ "$EXIT_CODE" = "0" ]; then
      echo "=== Job completed successfully (exit code: 0) ==="
      exit 0
    else
      echo "=== Job failed (exit code: $EXIT_CODE) ==="
      exit "$EXIT_CODE"
    fi
  fi

  # Job exists, check its status
  JOB_COMPLETE=$(kubectl_cmd get job "${JOB_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
  JOB_FAILED=$(kubectl_cmd get job "${JOB_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")

  if [ "$JOB_COMPLETE" = "True" ]; then
    echo "=== Job completed successfully ==="
    exit 0
  fi

  if [ "$JOB_FAILED" = "True" ]; then
    echo "=== Job failed ==="
    EXIT_CODE=$(kubectl_cmd get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "1")
    exit "${EXIT_CODE:-1}"
  fi

  # Job still running, wait
  sleep $POLL_INTERVAL
  WAITED=$((WAITED + POLL_INTERVAL))
done

echo "=== Timeout waiting for job completion ==="
exit 1
