#!/bin/bash
# ============================================================================
# Shared configuration for deploy.sh / destroy.sh / sync-membership.sh
#
# Naming follows the convention already in use in this subscription:
#   <resource-abbreviation>-<component>-<environment>-<region>-<instance>
# for example  rg-rls-demo-swedencentral-001
#
# Resource abbreviations are the Cloud Adoption Framework ones:
#   https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations
#
# Resources whose names must be globally unique across Azure (SQL server,
# storage account, function apps, APIM) take a short deterministic hash of the
# subscription ID instead of the instance number, so a redeploy always lands on
# the same names but two subscriptions never collide.
#
# Nothing here is secret and nothing identifies a tenant: subscription, tenant
# and owner are read from the active az login session.
#
# Override anything via environment variables, for example
#   ENVIRONMENT=test LOCATION=northeurope ./deploy.sh
# ============================================================================

# --- Settings from setup.sh --------------------------------------------------
# Run ./setup.sh in the repository root to create this. Environment variables
# still win, so CI can set them directly and skip setup.sh entirely.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/.env" ]; then
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/.env"
fi

# --- Identity: taken from the current az session, never hardcoded ------------
: "${SUBSCRIPTION_ID:=$(az account show --query id -o tsv 2>/dev/null)}"
: "${TENANT_ID:=$(az account show --query tenantId -o tsv 2>/dev/null)}"
: "${SQL_ADMIN_UPN:=$(az account show --query user.name -o tsv 2>/dev/null)}"

if [ -z "${SUBSCRIPTION_ID:-}" ]; then
    echo "ERROR: not logged in. Run 'az login' first, then ./setup.sh" >&2
    return 1 2>/dev/null || exit 1
fi

# --- Naming components -------------------------------------------------------
: "${COMPONENT:=rls}"
: "${ENVIRONMENT:=demo}"
: "${INSTANCE:=001}"

# Some regions periodically stop accepting new Azure SQL servers
# (RegionDoesNotAllowProvisioning). If deploy.sh fails on that, set LOCATION to
# another region and re-run.
: "${LOCATION:=swedencentral}"

: "${UNIQUE:=$(printf '%s' "$SUBSCRIPTION_ID" | md5sum | cut -c1-6)}"

BASE="${COMPONENT}-${ENVIRONMENT}-${LOCATION}"

# --- Resource names ----------------------------------------------------------
: "${RESOURCE_GROUP:=rg-${BASE}-${INSTANCE}}"

: "${SQL_SERVER_NAME:=sql-${BASE}-${UNIQUE}}"
: "${SQL_DB_NAME:=sqldb-${BASE}-${INSTANCE}}"
: "${SQL_DB_SKU:=Basic}"

# Storage account names allow only lowercase alphanumerics, 3-24 characters.
: "${STORAGE_ACCOUNT:=st${COMPONENT}${ENVIRONMENT}${UNIQUE}}"
: "${STORAGE_SKU:=Standard_LRS}"

: "${ASP_NAME:=asp-${BASE}-${INSTANCE}}"
: "${ASP_SKU:=B1}"
: "${FUNCAPP_GRAPHQL:=func-${COMPONENT}-gql-${ENVIRONMENT}-${LOCATION}-${UNIQUE}}"
: "${FUNCAPP_REST:=func-${COMPONENT}-rest-${ENVIRONMENT}-${LOCATION}-${UNIQUE}}"

: "${APPINSIGHTS_NAME:=appi-${BASE}-${INSTANCE}}"

: "${APIM_NAME:=apim-${BASE}-${UNIQUE}}"
: "${APIM_SKU:=Developer}"
: "${APIM_PUBLISHER_EMAIL:=$SQL_ADMIN_UPN}"
: "${APIM_PUBLISHER_NAME:=RLS Demo}"

# --- Demo Entra groups -------------------------------------------------------
# A small number of REAL groups, used to prove the identity path end to end.
# Scale is demonstrated separately with synthetic group IDs, see
# infra/sql/04_seed_demo_data.sql for the reasoning.
#
# These live in the directory, not in the resource group, so destroy.sh has to
# remove them explicitly.
: "${DEMO_GROUP_PREFIX:=${COMPONENT}-${ENVIRONMENT}}"
DEMO_GROUPS=(
    "${DEMO_GROUP_PREFIX}-alpha-read"
    "${DEMO_GROUP_PREFIX}-alpha-write"
    "${DEMO_GROUP_PREFIX}-beta-read"
    "${DEMO_GROUP_PREFIX}-beta-write"
)

# --- Demo users --------------------------------------------------------------
# Whoever deploys becomes the Entra admin and therefore connects as dbo, which
# bypasses RLS by design. Filtering is only visible when an ordinary user signs
# in, so name two of them:
#
#   read-write user : alpha read + alpha write   (see and change project 1)
#   read-only  user : beta read                  (see project 2, change nothing)
#
# These are specific to your directory, so there is no useful default. Set them
# with ./setup.sh, or export them before running deploy.sh. Leaving them empty
# is fine: everything deploys and the SQL tests still pass, you just cannot
# demonstrate filtering over HTTP.
: "${DEMO_USER_READWRITE:=}"
: "${DEMO_USER_READONLY:=}"

# --- Demo data size ----------------------------------------------------------
: "${PROJECT_COUNT:=2000}"
: "${DOCUMENT_COUNT:=100000}"

# --- Tags --------------------------------------------------------------------
# Matches the tag schema already used by the other resource groups here.
: "${TAG_APPLICATION:=dataplatform}"
: "${TAG_COST_CENTER:=shared}"
: "${TAG_CRITICALITY:=low}"
: "${TAG_DATA_CLASSIFICATION:=internal}"
: "${TAG_LIFECYCLE:=poc}"
: "${TAG_MANAGED_BY:=azure-cli}"
: "${TAG_OWNER:=data-platform-team}"
: "${TAG_PROJECT:=sql-rls-entra-groups}"

TAGS=(
    "application=${TAG_APPLICATION}"
    "costCenter=${TAG_COST_CENTER}"
    "criticality=${TAG_CRITICALITY}"
    "dataClassification=${TAG_DATA_CLASSIFICATION}"
    "environment=${ENVIRONMENT}"
    "lifecycle=${TAG_LIFECYCLE}"
    "managedBy=${TAG_MANAGED_BY}"
    "owner=${TAG_OWNER}"
    "project=${TAG_PROJECT}"
)

export SUBSCRIPTION_ID TENANT_ID SQL_ADMIN_UPN
export COMPONENT ENVIRONMENT INSTANCE LOCATION UNIQUE BASE
export RESOURCE_GROUP
export SQL_SERVER_NAME SQL_DB_NAME SQL_DB_SKU
export STORAGE_ACCOUNT STORAGE_SKU
export ASP_NAME ASP_SKU FUNCAPP_GRAPHQL FUNCAPP_REST
export APPINSIGHTS_NAME
export APIM_NAME APIM_SKU APIM_PUBLISHER_EMAIL APIM_PUBLISHER_NAME
export DEMO_GROUP_PREFIX DEMO_USER_READWRITE DEMO_USER_READONLY
export PROJECT_COUNT DOCUMENT_COUNT
