# Consolidate Docker Compose Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `docker-compose-dagster.yml` and `docker-compose-snowflake.yml` into the main `docker-compose.yml` using profiles, then delete the standalone files and fix stale script references.

**Architecture:** The main compose already uses YAML anchors (`x-starlake-ui-common`, `&starlake-ui-common-env`, `&starlake-ui-common-depends-on`) and profile-based service selection. We follow the existing `starlake-ui-airflow3` pattern to add `starlake-dagster`, `starlake-ui-dagster`, and `starlake-ui-snowflake` services. Shell scripts with stale `airflow` profile references get updated to `airflow3`.

**Tech Stack:** Docker Compose (modern format, no `version` key), YAML anchors

---

## File Structure

| Action | File | Purpose |
|--------|------|---------|
| Modify | `docker-compose.yml` | Add 3 new services under dagster/snowflake profiles |
| Delete | `docker-compose-dagster.yml` | Replaced by main compose |
| Delete | `docker-compose-snowflake.yml` | Replaced by main compose |
| Modify | `run.sh` | Fix `--profile airflow` to `--profile airflow3` |
| Modify | `cloud-data-stack.sh` | Fix `--profile airflow` to `--profile airflow3` |
| Modify | `.env` | Fix `COMPOSE_PROFILES=airflow` to `airflow3` |
| Delete | `.env.dagster.docker` | Obsolete — dagster config now in main compose |

---

### Task 1: Add `starlake-dagster` service to main compose

**Files:**
- Modify: `docker-compose.yml` (insert after `starlake-ui-airflow3` block, before `starlake-agent`)

- [ ] **Step 1: Add the `starlake-dagster` service**

Insert the following block after line 178 (end of `starlake-ui-airflow3`) and before line 179 (`# Starlake Agent service`):

```yaml
  starlake-dagster:
    profiles:
      - dagster
    image: starlakeai/starlake-dagster:latest
    build:
      context: .
      dockerfile: Dockerfile_dagster
    container_name: starlake-dagster
    restart: on-failure
    depends_on:
      starlake-db:
        condition: service_healthy
    networks:
      - starlake-network
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${PROJECTS_DATA_PATH:-./projects}:/projects
      - ${PROJECTS_DATA_PATH:-./projects}/dags:/opt/dagster/app/dags
      - ${DAGSTER_LOGS:-./dagster/logs}:/opt/dagster/app/logs
      - ${DAGSTER_STORAGE:-./dagster/storage}:/opt/dagster/home/storage
    ports:
      - ${SL_DAGSTER_PORT:-3000}:3000
    environment:
      DAGSTER_PG_USERNAME: ${SL_POSTGRES_USER:-dbuser}
      DAGSTER_PG_PASSWORD: ${SL_POSTGRES_PASSWORD:-dbuser123}
      DAGSTER_PG_HOST: starlake-db
      DAGSTER_PG_DB: ${DAGSTER_DB:-dagster}
      SL_HOME: /app/starlake
    entrypoint: >
      /bin/bash -c "
      sleep 10 &&
      pip install --no-cache-dir starlake-dagster docker --upgrade --force-reinstall &&
      python3 dagster_code_locations.py &&
      service cron --full-restart &
      exec dagster-webserver -h 0.0.0.0 -p 3000 --path-prefix /dagster"
```

- [ ] **Step 2: Validate syntax**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=dagster docker compose config --services`
Expected output should include: `starlake-db`, `starlake-dagster`

---

### Task 2: Add `starlake-ui-dagster` service to main compose

**Files:**
- Modify: `docker-compose.yml` (insert immediately after the `starlake-dagster` block from Task 1)

- [ ] **Step 1: Add the `starlake-ui-dagster` service**

Insert immediately after the `starlake-dagster` service:

```yaml
  starlake-ui-dagster:
    profiles:
      - dagster
    <<: *starlake-ui-common
    depends_on:
      <<: *starlake-ui-common-depends-on
      starlake-dagster:
        condition: service_started
    environment:
      <<: *starlake-ui-common-env
      SL_API_ORCHESTRATOR_PRIVATE_URL: http://starlake-dagster:3000/dagster/
      LOAD_DAG_REF: dagster_load_shell
      TRANSFORM_DAG_REF: dagster_transform_shell
    entrypoint: >
      /bin/bash -c "
      sleep 10 &&
      python3 -m pip install --break-system-packages --no-cache-dir starlake-dagster docker --upgrade &&
      /usr/bin/tini -- /app/run-api.sh"
```

- [ ] **Step 2: Validate syntax**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=dagster docker compose config --services`
Expected output should include: `starlake-db`, `starlake-dagster`, `starlake-ui-dagster`

---

### Task 3: Add `starlake-ui-snowflake` service to main compose

**Files:**
- Modify: `docker-compose.yml` (insert after `starlake-ui-dagster` block from Task 2)

- [ ] **Step 1: Add the `starlake-ui-snowflake` service**

Insert immediately after the `starlake-ui-dagster` service:

```yaml
  starlake-ui-snowflake:
    profiles:
      - snowflake
    <<: *starlake-ui-common
    environment:
      <<: *starlake-ui-common-env
      SL_API_ORCHESTRATOR_PRIVATE_URL:
      LOAD_DAG_REF: snowflake_load_sql
      TRANSFORM_DAG_REF: snowflake_transform_sql
    entrypoint: >
      /bin/bash -c "
      sleep 10 &&
      python3 -m pip install --break-system-packages --no-cache-dir starlake-snowflake --upgrade &&
      /usr/bin/tini -- /app/run-api.sh"
```

- [ ] **Step 2: Validate syntax**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=snowflake docker compose config --services`
Expected output should include: `starlake-db`, `starlake-ui-snowflake`

---

### Task 4: Validate all profiles work together

**Files:** None (validation only)

- [ ] **Step 1: Validate airflow3 profile (regression check)**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=airflow3 docker compose config --services`
Expected: `starlake-airflow3`, `starlake-db`, `starlake-ui-airflow3`

- [ ] **Step 2: Validate dagster profile**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=dagster docker compose config --services`
Expected: `starlake-dagster`, `starlake-db`, `starlake-ui-dagster`

- [ ] **Step 3: Validate snowflake profile**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=snowflake docker compose config --services`
Expected: `starlake-db`, `starlake-ui-snowflake`

- [ ] **Step 4: Validate combined profiles**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=airflow3,gizmo,minio,ai docker compose config --services`
Expected: all airflow3 services plus gizmo, minio, createbuckets, starlake-agent

- [ ] **Step 5: Full config render check for dagster**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && COMPOSE_PROFILES=dagster docker compose config | head -20`
Verify: no YAML errors, services render correctly

---

### Task 5: Delete standalone compose files

**Files:**
- Delete: `docker-compose-dagster.yml`
- Delete: `docker-compose-snowflake.yml`
- Delete: `.env.dagster.docker`

- [ ] **Step 1: Delete the three files**

```bash
cd /Users/hayssams/git/public/starlake-data-stack
rm docker-compose-dagster.yml docker-compose-snowflake.yml .env.dagster.docker
```

- [ ] **Step 2: Verify deletion**

Run: `ls docker-compose*.yml`
Expected: only `docker-compose.yml` remains

---

### Task 6: Fix stale profile references in shell scripts

**Files:**
- Modify: `run.sh`
- Modify: `cloud-data-stack.sh`
- Modify: `.env`

- [ ] **Step 1: Fix `run.sh`**

Replace entire content with:
```bash
docker compose --profile airflow3 --profile gizmo up
```

(Changed `--profile airflow` to `--profile airflow3`, removed duplicate `--profile gizmo`)

- [ ] **Step 2: Fix `cloud-data-stack.sh`**

Replace entire content with:
```bash
docker compose --profile airflow3 up --build
```

(Changed `--profile airflow` to `--profile airflow3`)

- [ ] **Step 3: Fix `.env`**

Replace line 1:
```
COMPOSE_PROFILES=airflow3
```

(Changed `airflow` to `airflow3`)

- [ ] **Step 4: Verify scripts parse correctly**

Run: `cd /Users/hayssams/git/public/starlake-data-stack && bash -n run.sh && bash -n cloud-data-stack.sh && echo "OK"`
Expected: `OK`

---

### Task 7: Commit

- [ ] **Step 1: Stage and commit all changes**

```bash
cd /Users/hayssams/git/public/starlake-data-stack
git add docker-compose.yml run.sh cloud-data-stack.sh .env
git rm docker-compose-dagster.yml docker-compose-snowflake.yml .env.dagster.docker
git commit -m "Consolidate dagster/snowflake compose files into main docker-compose.yml

Merge docker-compose-dagster.yml and docker-compose-snowflake.yml into the main
docker-compose.yml using profiles, following the existing airflow3 pattern with
YAML anchors. Fix stale 'airflow' profile references in run.sh, cloud-data-stack.sh,
and .env to use 'airflow3'. Remove obsolete .env.dagster.docker.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
