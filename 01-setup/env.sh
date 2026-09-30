#!/usr/bin/env bash
# This script will help assigning a value to the main variables needed for this workshop and will
# print to stdout the credentials to access ACS Central.
#
# It must be SOURCED, not executed, so the variables stay in your shell:
#   source ./env.sh
#
# Sets:  ROX_ENDPOINT, ROX_CENTRAL_ADDRESS, ROX_API_TOKEN (Admin role), ROX_CI_TOKEN (Continuous
#        Integration role, used in step 07).
# The admin password is only used to create the tokens: it is never exported, so roxctl
# authenticates with ROX_API_TOKEN and does not look for an identity provider.
# Sourcing it again in the same shell keeps the existing tokens instead of creating new ones.

# Refuse to run as "./env.sh": the exports would be lost when the subshell exits.
if [ -n "${ZSH_EVAL_CONTEXT:-}" ]; then
  case "$ZSH_EVAL_CONTEXT" in
    *:file*) ;;
    *) echo "ERROR: run it with: source ${0}" >&2; exit 1 ;;
  esac
elif [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "ERROR: run it with: source ${0}" >&2
  exit 1
fi

export ROX_ENDPOINT="$(oc --context security-ws get route central -n stackrox -o jsonpath='{.spec.host}'):443"
if [ "$ROX_ENDPOINT" = ":443" ]; then
  echo "ERROR: Central route not found. Is the 'security-ws' context logged in, and is Central deployed (step 01)?" >&2
  unset ROX_ENDPOINT
  return 1
fi
export ROX_CENTRAL_ADDRESS=${ROX_ENDPOINT}

_rox_admin_password="$(oc --context security-ws get secret central-htpasswd -n stackrox \
  -o go-template='{{index .data "password" | base64decode}}')"
echo "Portal: https://${ROX_ENDPOINT%:443}   user: admin   password: ${_rox_admin_password}"

# Create a token only if the variable is not already set to a real token.
if [ -z "${ROX_API_TOKEN:-}" ] || [ "$ROX_API_TOKEN" = "null" ]; then
  export ROX_API_TOKEN="$(curl -sk -u "admin:${_rox_admin_password}" \
    "https://${ROX_ENDPOINT}/v1/apitokens/generate" \
    -d '{"name":"workshop-admin","roles":["Admin"]}' | jq -r .token)"
fi
if [ -z "${ROX_CI_TOKEN:-}" ] || [ "$ROX_CI_TOKEN" = "null" ]; then
  export ROX_CI_TOKEN="$(curl -sk -u "admin:${_rox_admin_password}" \
    "https://${ROX_ENDPOINT}/v1/apitokens/generate" \
    -d '{"name":"ci-gate","roles":["Continuous Integration"]}' | jq -r .token)"
fi
unset _rox_admin_password

# A failed request (Central not ready, wrong password) returns "null" instead of a token.
for _v in ROX_API_TOKEN ROX_CI_TOKEN; do
  eval "_t=\${$_v:-}"
  if [ -z "$_t" ] || [ "$_t" = "null" ]; then
    echo "ERROR: $_v could not be created. Check that Central is ready, then run 'source ./env.sh' again." >&2
    unset "$_v"
  else
    echo "$_v is set."
  fi
done
unset _v _t
