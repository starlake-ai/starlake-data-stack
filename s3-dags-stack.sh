#!/usr/bin/env bash
set -euo pipefail

SL_API_APP_TYPE=ducklake docker compose --profile airflow --profile minio --profile gizmo up --build