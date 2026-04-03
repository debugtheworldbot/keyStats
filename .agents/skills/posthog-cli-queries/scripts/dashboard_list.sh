#!/usr/bin/env bash
set -euo pipefail

cred_file="${HOME}/.posthog/credentials.json"

if [[ ! -f "${cred_file}" ]]; then
  echo "Missing credentials file: ${cred_file}" >&2
  exit 1
fi

token="$(jq -r '.token // empty' "${cred_file}")"
host="$(jq -r '.host // empty' "${cred_file}")"
env_id="$(jq -r '.env_id // empty' "${cred_file}")"

if [[ -z "${token}" || -z "${host}" || -z "${env_id}" ]]; then
  echo "Expected host, token, and env_id in ${cred_file}" >&2
  exit 1
fi

curl -fsS \
  -H "Authorization: Bearer ${token}" \
  "${host%/}/api/dashboard/" |
  jq -r --arg env_id "${env_id}" '
    if (.results | length) == 0 then
      "No dashboards found for environment \($env_id)"
    else
      .results[]
      | [.id, .name, (.pinned // false), (.last_accessed_at // ""), (.last_viewed_at // "")]
      | @tsv
    end
  '
