#!/usr/bin/env bash

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

export JAVA_HOME=/opt/java/openjdk
export PATH=$JAVA_HOME/bin:$PATH

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

/app/starlake/starlake.sh $command ${arguments[@]} 2>&1
