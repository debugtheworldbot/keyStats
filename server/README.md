# KeyStats Cloud Sync Server

Private Go backend for cross-platform stats sync (macOS / Windows).

## Privacy notes

This server stores **aggregate statistics only**:

- Daily counters (key presses, clicks, distances)
- Optional `key_press_counts` JSON: per-key **counts** (e.g. `"Cmd+C": 42`), not typed content
- Optional `app_stats` JSON: per-app aggregate counts

For a public release, consider:

- Omitting `key_press_counts` / `app_stats` from sync payloads
- Encrypting JSON columns at rest
- Adding data retention / deletion APIs

## Quick start

```bash
cd server
docker compose up -d   # optional local Postgres
cp .env.example .env   # edit JWT_SECRET and DATABASE_URL
go run .               # auto-loads server/.env
```

Server listens on `:8080` by default.

## API

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/v1/auth/register` | No | Register `{username, password}` |
| POST | `/api/v1/auth/login` | No | Login, returns JWT |
| GET | `/api/v1/devices` | Bearer | List user's devices |
| POST | `/api/v1/devices` | Bearer | Register/update device |
| PUT | `/api/v1/sync/stats` | Bearer | Upsert one day's stats for a device |
| POST | `/api/v1/sync/stats/bulk` | Bearer | Bulk upsert historical days |
| GET | `/api/v1/sync/stats` | Bearer | Pull stats (`?from=&to=&device_id=`) |

### Device-scoped storage

Primary key is `(user_id, device_id, date)` so Mac and Windows stats for the same day remain separate.

## Environment

| Variable | Required | Default |
|----------|----------|---------|
| `DATABASE_URL` | Yes | — |
| `JWT_SECRET` | Yes | — |
| `ADDR` | No | `:8080` |
| `JWT_EXPIRATION` | No | `720h` |
| `MIGRATIONS_DIR` | No | `migrations` |
