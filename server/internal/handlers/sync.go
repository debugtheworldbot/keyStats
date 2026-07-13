package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"keystats-server/internal/middleware"
	"keystats-server/internal/models"
)

type SyncHandler struct {
	Pool *pgxpool.Pool
}

func (h *SyncHandler) Upsert(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var req models.UpsertStatsRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.DeviceID == "" || req.Date == "" {
		writeError(w, http.StatusBadRequest, "device_id and date are required")
		return
	}

	accepted, version, err := h.upsertOne(r, userID, req.DeviceID, req.Date, req.Version, req.Stats)
	if err != nil {
		if err == pgx.ErrNoRows {
			writeError(w, http.StatusNotFound, "device not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to upsert stats")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"accepted": accepted, "version": version})
}

func (h *SyncHandler) BulkUpsert(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var req models.BulkUpsertStatsRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.DeviceID == "" || len(req.Records) == 0 {
		writeError(w, http.StatusBadRequest, "device_id and records are required")
		return
	}

	accepted := 0
	for _, record := range req.Records {
		ok, _, err := h.upsertOne(r, userID, req.DeviceID, record.Date, record.Version, record.Stats)
		if err != nil {
			if err == pgx.ErrNoRows {
				writeError(w, http.StatusNotFound, "device not found")
				return
			}
			writeError(w, http.StatusInternalServerError, "failed to bulk upsert stats")
			return
		}
		if ok {
			accepted++
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{"accepted": accepted, "total": len(req.Records)})
}

func (h *SyncHandler) List(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	from := r.URL.Query().Get("from")
	to := r.URL.Query().Get("to")
	deviceID := r.URL.Query().Get("device_id")

	query := `
		SELECT ds.device_id::text, d.platform, d.device_name, ds.date::text,
		       ds.version, ds.updated_at,
		       ds.key_presses, ds.left_clicks, ds.right_clicks,
		       ds.side_back_clicks, ds.side_forward_clicks,
		       ds.mouse_distance, ds.scroll_distance,
		       ds.peak_kps, ds.peak_cps,
		       ds.key_press_counts, ds.app_stats
		FROM daily_stats ds
		JOIN devices d ON d.id = ds.device_id
		WHERE ds.user_id = $1::uuid`
	args := []any{userID}
	argIndex := 2

	if from != "" {
		query += ` AND ds.date >= $` + strconv.Itoa(argIndex) + `::date`
		args = append(args, from)
		argIndex++
	}
	if to != "" {
		query += ` AND ds.date <= $` + strconv.Itoa(argIndex) + `::date`
		args = append(args, to)
		argIndex++
	}
	if deviceID != "" {
		query += ` AND ds.device_id = $` + strconv.Itoa(argIndex) + `::uuid`
		args = append(args, deviceID)
	}
	query += ` ORDER BY ds.date DESC, d.platform ASC, d.device_name ASC`

	rows, err := h.Pool.Query(r.Context(), query, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list stats")
		return
	}
	defer rows.Close()

	records := make([]models.StatsRecordResponse, 0)
	for rows.Next() {
		var rec models.StatsRecordResponse
		var keyCounts []byte
		var appStats []byte
		if err := rows.Scan(
			&rec.DeviceID, &rec.Platform, &rec.DeviceName, &rec.Date,
			&rec.Version, &rec.UpdatedAt,
			&rec.Stats.KeyPresses, &rec.Stats.LeftClicks, &rec.Stats.RightClicks,
			&rec.Stats.SideBackClicks, &rec.Stats.SideForwardClicks,
			&rec.Stats.MouseDistance, &rec.Stats.ScrollDistance,
			&rec.Stats.PeakKPS, &rec.Stats.PeakCPS,
			&keyCounts, &appStats,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan stats")
			return
		}
		rec.Stats.Date = rec.Date
		if len(keyCounts) > 0 {
			_ = json.Unmarshal(keyCounts, &rec.Stats.KeyPressCounts)
		}
		if len(appStats) > 0 {
			rec.Stats.AppStats = appStats
		}
		records = append(records, rec)
	}

	writeJSON(w, http.StatusOK, map[string]any{"records": records})
}

func (h *SyncHandler) upsertOne(r *http.Request, userID, deviceID, date string, version int64, stats models.DailyStatsPayload) (bool, int64, error) {
	keyCounts, err := json.Marshal(stats.KeyPressCounts)
	if err != nil {
		return false, 0, err
	}
	appStats := stats.AppStats
	if appStats == nil {
		appStats = json.RawMessage(`{}`)
	}

	var accepted bool
	var storedVersion int64
	err = h.Pool.QueryRow(r.Context(), `
		WITH owned_device AS (
			SELECT id FROM devices WHERE id = $1::uuid AND user_id = $2::uuid
		),
		upsert AS (
			INSERT INTO daily_stats (
				user_id, device_id, date,
				key_presses, left_clicks, right_clicks,
				side_back_clicks, side_forward_clicks,
				mouse_distance, scroll_distance,
				peak_kps, peak_cps,
				key_press_counts, app_stats,
				version, updated_at
			)
			SELECT
				$2::uuid, $1::uuid, $3::date,
				$4, $5, $6, $7, $8, $9, $10, $11, $12,
				$13::jsonb, $14::jsonb,
				$15, now()
			FROM owned_device
			ON CONFLICT (user_id, device_id, date) DO UPDATE SET
				key_presses = EXCLUDED.key_presses,
				left_clicks = EXCLUDED.left_clicks,
				right_clicks = EXCLUDED.right_clicks,
				side_back_clicks = EXCLUDED.side_back_clicks,
				side_forward_clicks = EXCLUDED.side_forward_clicks,
				mouse_distance = EXCLUDED.mouse_distance,
				scroll_distance = EXCLUDED.scroll_distance,
				peak_kps = EXCLUDED.peak_kps,
				peak_cps = EXCLUDED.peak_cps,
				key_press_counts = EXCLUDED.key_press_counts,
				app_stats = EXCLUDED.app_stats,
				version = EXCLUDED.version,
				updated_at = now()
			WHERE daily_stats.version <= EXCLUDED.version
			RETURNING version, true AS accepted
		)
		SELECT COALESCE((SELECT version FROM upsert), 0),
		       COALESCE((SELECT accepted FROM upsert), false)
	`, deviceID, userID, date,
		stats.KeyPresses, stats.LeftClicks, stats.RightClicks,
		stats.SideBackClicks, stats.SideForwardClicks,
		stats.MouseDistance, stats.ScrollDistance,
		stats.PeakKPS, stats.PeakCPS,
		keyCounts, appStats, version,
	).Scan(&storedVersion, &accepted)
	if err != nil {
		return false, 0, err
	}
	if storedVersion == 0 && !accepted {
		return false, 0, pgx.ErrNoRows
	}

	_, _ = h.Pool.Exec(r.Context(),
		`UPDATE devices SET last_sync_at = $2 WHERE id = $1::uuid`, deviceID, time.Now())

	return accepted, storedVersion, nil
}
