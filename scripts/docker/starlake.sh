#!/usr/bin/env bash

old_ifs="$IFS"

# Check if at least one argument is passed
if [ "$#" -eq 0 ]; then
  echo "No arguments provided. Usage: starlake <command> [args...]"
  exit 1
fi

# Parse command and options
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

# Convert options to Docker -e arguments
docker_envs=()
if [ -n "$options" ]; then
    IFS=',' read -ra env_array <<< "$options"
    for env in "${env_array[@]}"; do
        docker_envs+=("-e" "$env")
    done
    IFS="$old_ifs"
fi

# Run the docker command
docker exec -i "${docker_envs[@]}" starlake-ui /app/starlake/starlake.sh "$command" "${arguments[@]}"
