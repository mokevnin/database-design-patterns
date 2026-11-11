#!/bin/sh
set -eu

# Use only a disposable PostgreSQL 18 cluster with local trust authentication.
assets=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
maintenance=${PGDATABASE:-postgres}
database=
slug=
count=0

# These fixed names belong to the tenant labs. Never remove existing objects.
occupied=$(psql -X -v ON_ERROR_STOP=1 -At --dbname="$maintenance" --command="
    SELECT count(*) FROM (
        SELECT rolname FROM pg_roles WHERE rolname IN
            ('ss_app', 'st_owner', 'st_app_a', 'st_app_b',
             'dt_owner', 'dt_app_a', 'dt_app_b', 'audit_example_app')
        UNION ALL
        SELECT datname FROM pg_database WHERE datname IN ('dt_a', 'dt_b')
    ) AS lab_objects;")
if [ "$occupied" -ne 0 ]; then
    printf '%s\n' 'Lab roles or databases already exist; use a fresh cluster.' >&2
    exit 1
fi

cleanup() {
    cleanup_failed=0
    if [ -z "$database" ]; then
        return 0
    fi
    if [ "$slug" = database-per-tenant ]; then
        for auxiliary in dt_a dt_b; do
            dropdb --maintenance-db="$maintenance" --if-exists "$auxiliary" || cleanup_failed=1
        done
    fi
    dropdb --maintenance-db="$maintenance" --if-exists "$database" || cleanup_failed=1
    roles=
    case "$slug" in
        shared-schema) roles='ss_app' ;;
        schema-per-tenant) roles='st_app_a st_app_b st_owner' ;;
        database-per-tenant) roles='dt_app_a dt_app_b dt_owner' ;;
    esac
    for role in $roles; do
        psql -X -v ON_ERROR_STOP=1 --dbname="$maintenance" \
            --command="DROP ROLE IF EXISTS $role" || cleanup_failed=1
    done
    if [ "$cleanup_failed" -ne 0 ]; then
        return 1
    fi
    database=
}

trap 'result=$?; trap - 0; if ! cleanup; then result=1; fi; exit "$result"' 0
trap 'exit 130' INT
trap 'exit 143' TERM

# Each chapter has exactly one script named after its directory.
for script in "$assets"/*/*.sql; do
    slug=${script##*/}
    slug=${slug%.sql}
    next=$((count + 1))
    candidate=sql_lab_$$_$next
    printf '\nRUN %s\n' "$slug"
    # Set the cleanup target only after successfully creating our own database.
    createdb --maintenance-db="$maintenance" --template=template0 "$candidate"
    database=$candidate
    if psql -X -v ON_ERROR_STOP=1 --dbname="$database" --file="$script"; then
        cleanup
        count=$next
        printf 'PASS %s\n' "$slug"
    else
        result=$?
        printf 'FAIL %s (psql exit %s)\n' "$slug" "$result" >&2
        exit "$result"
    fi
done

printf '\nPASS: %s scripts\n' "$count"
