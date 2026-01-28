#!/usr/bin/env bash
# Starlake CLI wrapper for Kubernetes (shell mode - no Docker)
# This script executes starlake commands locally instead of via docker exec

old_ifs="$IFS"

# Check if at least one argument is passed
if [ "$#" -eq 0 ]; then
  echo "No arguments provided. Usage: starlake <command> [args...]"
  exit 1
fi

options=""
command="$1"
shift

arguments=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--options) options="$2"; shift 2 ;;
        *) arguments+=("$1"); shift ;;
    esac
done

# Set Java home if available
if [ -d "/opt/java/openjdk" ]; then
  export JAVA_HOME=/opt/java/openjdk
  export PATH=$JAVA_HOME/bin:$PATH
fi

# Export environment variables from --options, if provided
if [ -n "$options" ]; then
    IFS=',' read -ra env_array <<< "$options"
    for env in "${env_array[@]}"; do
        name="${env%%=*}"
        value="${env#*=}"

        # Remove surrounding quotes (both single and double) from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        # Export the variable
        export "$name=$value"
    done
    IFS="$old_ifs"
fi

# Execute starlake directly (shell mode, not docker mode)
# The starlake.sh script should be in /app/starlake/ copied from UI image
STARLAKE_SCRIPT=""

if [ -x "/app/starlake/starlake.sh" ]; then
  STARLAKE_SCRIPT="/app/starlake/starlake.sh"
elif [ -x "/shared-tools/starlake/starlake.sh" ]; then
  STARLAKE_SCRIPT="/shared-tools/starlake/starlake.sh"
elif [ -x "/app/starlake/starlake" ] && file /app/starlake/starlake 2>/dev/null | grep -q "script"; then
  # starlake might be the shell script without .sh extension
  STARLAKE_SCRIPT="/app/starlake/starlake"
fi

if [ -n "$STARLAKE_SCRIPT" ]; then
  exec "$STARLAKE_SCRIPT" "$command" "${arguments[@]}" 2>&1
else
  echo "ERROR: starlake.sh executable not found"
  echo "Searched locations:"
  echo "  /app/starlake/starlake.sh"
  echo "  /shared-tools/starlake/starlake.sh"
  echo "  /app/starlake/starlake"
  echo ""
  echo "Available files in /app/starlake/:"
  ls -la /app/starlake/ 2>/dev/null || echo "  Directory not found"
  echo ""
  echo "Available files in /shared-tools/starlake/:"
  ls -la /shared-tools/starlake/ 2>/dev/null || echo "  Directory not found"
  exit 1
fi