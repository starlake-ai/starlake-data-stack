#!/bin/bash
set -e
set -x

echo "Starting Airflow 3 Entrypoint..."

# Install/Update Starlake Airflow
# Removed --force-reinstall to avoid breaking pre-installed dependencies
echo "Installing/Updating starlake-airflow..."
# python3 -m pip install --no-cache-dir starlake-airflow docker --upgrade
export PYTHONPATH=/opt/airflow/dags:$PYTHONPATH

# Check DB Connection
echo "Checking DB connection string..."
airflow config get-value database sql_alchemy_conn

# Migrate Database
echo "Running Database Migration..."
airflow db migrate

# Create Admin User
echo "Creating Admin User..."
airflow users create \
    --username "${AIRFLOW_USERNAME:-airflow}" \
    --firstname "${AIRFLOW_FIRSTNAME:-airflow}" \
    --lastname "${AIRFLOW_LASTNAME:-airflow}" \
    --role Admin \
    --email "${AIRFLOW_EMAIL:-admin@example.com}" \
    --password "${AIRFLOW_PASSWORD:-airflow}" || echo "User creation failed or user already exists"

# Start Services
echo "Starting Airflow Services..."
airflow api-server &
airflow scheduler &
exec airflow dag-processor &

wait -n
exit $?
