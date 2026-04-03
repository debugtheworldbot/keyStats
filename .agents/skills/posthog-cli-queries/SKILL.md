---
name: posthog-cli-queries
description: Use when querying this project's PostHog data from the terminal, including recent events, event breakdowns, active-user metrics, and dashboard metadata or cached insight results.
---

# PostHog CLI Queries

Query this project's PostHog data from the terminal without guessing command syntax.

## When To Use

- The user asks to inspect PostHog events, trends, or dashboard data
- The task needs real data from this project's PostHog environment
- The user wants a repeatable terminal command instead of clicking in the PostHog UI

## Preconditions

- `posthog-cli` must be installed and authenticated
- Query commands need a personal API key with `query:read`
- Dashboard API helpers read `~/.posthog/credentials.json`
- This project currently uses PostHog environment `292804` on `https://us.posthog.com`, but scripts read the active local credentials instead of hardcoding values

## Default Workflow

1. Verify auth:

```bash
posthog-cli exp query run 'SELECT 1 AS ok'
```

2. For event data, use `posthog-cli exp query run '<hogql>'`
3. For dashboard metadata or cached dashboard insight results, use the scripts in this skill because the CLI has no dedicated dashboard command
4. Return:
   - the exact command used
   - the key rows or aggregates
   - any metric caveats such as partial-day data, test-account filtering, or missing properties

Shell quoting rule:

- Use single quotes around HogQL when the query contains properties like `$app_version` or `$os`, otherwise the shell may expand them before the CLI sees the query

## Common Queries

Recent events:

```bash
posthog-cli exp query run 'SELECT event, timestamp FROM events ORDER BY timestamp DESC LIMIT 20'
```

Top events in the last 7 days:

```bash
posthog-cli exp query run 'SELECT event, count() AS c FROM events WHERE timestamp > now() - INTERVAL 7 DAY GROUP BY event ORDER BY c DESC LIMIT 15'
```

Top `pageview` pages in the last 7 days:

```bash
posthog-cli exp query run "SELECT properties.page_name AS page_name, count() AS c FROM events WHERE event = 'pageview' AND timestamp > now() - INTERVAL 7 DAY GROUP BY page_name ORDER BY c DESC LIMIT 15"
```

Top `click` targets in the last 7 days:

```bash
posthog-cli exp query run "SELECT properties.element_name AS element_name, count() AS c FROM events WHERE event = 'click' AND timestamp > now() - INTERVAL 7 DAY GROUP BY element_name ORDER BY c DESC LIMIT 15"
```

Recent app versions from events:

```bash
posthog-cli exp query run 'SELECT properties.$app_version AS app_version, count() AS c FROM events WHERE timestamp > now() - INTERVAL 7 DAY GROUP BY app_version ORDER BY c DESC LIMIT 20'
```

Recent OS breakdown:

```bash
posthog-cli exp query run 'SELECT properties.$os AS os, count(DISTINCT person_id) AS users FROM events WHERE timestamp > now() - INTERVAL 7 DAY GROUP BY os ORDER BY users DESC LIMIT 20'
```

Hourly volume in the last 24 hours:

```bash
posthog-cli exp query run 'SELECT toStartOfHour(timestamp) AS hour, count() AS c FROM events WHERE timestamp > now() - INTERVAL 24 HOUR GROUP BY hour ORDER BY hour DESC LIMIT 24'
```

## Dashboard Commands

List dashboards:

```bash
bash .agents/skills/posthog-cli-queries/scripts/dashboard_list.sh
```

Fetch a dashboard as JSON:

```bash
bash .agents/skills/posthog-cli-queries/scripts/dashboard_fetch.sh 1075953
```

Fetch a dashboard summary:

```bash
bash .agents/skills/posthog-cli-queries/scripts/dashboard_fetch.sh 1075953 --summary
```

Current known dashboard:

```bash
bash .agents/skills/posthog-cli-queries/scripts/dashboard_fetch.sh 1075953 --summary
```

## Dashboard Analysis Notes

- Dashboard results are usually cached insight payloads, so `last_refresh` matters
- Do not compare a partial current day against a full previous day without saying so explicitly
- Check `filterTestAccounts` before comparing tiles with each other
- If `$os` or `$app_version` has a large `null` bucket, call out that the property coverage is incomplete
- If event names overlap like `app_open` and `Application Opened`, mention that the taxonomy is split

## Useful jq Snippets

Extract tile names from a fetched dashboard JSON:

```bash
jq -r '.tiles[] | select(.insight != null) | [.id, .insight.id, .insight.name] | @tsv'
```

Show top breakdown rows from one insight result:

```bash
jq -r '.tiles[] | select(.insight.id==6334935) | .insight.result[] | [.label, .count, (.data[-1] // 0)] | @tsv'
```

## Failure Handling

- If `posthog-cli exp query run` says `missing required scope 'query:read'`, fix the personal API key scopes first
- If a query times out, narrow the date range or aggregate more aggressively
- If dashboard scripts fail, confirm `~/.posthog/credentials.json` exists and contains `host`, `token`, and `env_id`
