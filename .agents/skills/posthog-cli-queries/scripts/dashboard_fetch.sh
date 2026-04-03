#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <dashboard_id> [--summary]" >&2
  exit 1
fi

dashboard_id="$1"
mode="${2:-}"
cred_file="${HOME}/.posthog/credentials.json"

if [[ ! -f "${cred_file}" ]]; then
  echo "Missing credentials file: ${cred_file}" >&2
  exit 1
fi

token="$(jq -r '.token // empty' "${cred_file}")"
host="$(jq -r '.host // empty' "${cred_file}")"

if [[ -z "${token}" || -z "${host}" ]]; then
  echo "Expected host and token in ${cred_file}" >&2
  exit 1
fi

response="$(
  curl -fsS \
    -H "Authorization: Bearer ${token}" \
    "${host%/}/api/dashboard/${dashboard_id}"
)"

if [[ "${mode}" == "--summary" ]]; then
  jq -r '
    "Dashboard\t" + (.id | tostring) + "\t" + .name,
    (
      .tiles[]
      | select(.insight != null)
      | [
          (.id | tostring),
          (.insight.id | tostring),
          (
            if (.insight.name // "") != "" then .insight.name
            elif (.insight.derived_name // "") != "" then .insight.derived_name
            else (.insight.short_id // "")
            end
          ),
          (.insight.query.source.kind // ""),
          (.insight.query.source.interval // ""),
          ((.insight.result // [] | length) | tostring),
          (.last_refresh // .insight.last_refresh // "")
        ]
      | @tsv
    )
  ' <<<"${response}"
else
  jq '.' <<<"${response}"
fi
