package handlers

import (
	"net/http"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"keystats-server/internal/middleware"
	"keystats-server/internal/models"
)

type DeviceHandler struct {
	Pool *pgxpool.Pool
}

func (h *DeviceHandler) List(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	rows, err := h.Pool.Query(r.Context(), `
		SELECT id::text, user_id::text, platform, device_name, created_at, last_sync_at
		FROM devices
		WHERE user_id = $1::uuid
		ORDER BY created_at ASC`, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list devices")
		return
	}
	defer rows.Close()

	devices := make([]models.Device, 0)
	for rows.Next() {
		var d models.Device
		if err := rows.Scan(&d.ID, &d.UserID, &d.Platform, &d.DeviceName, &d.CreatedAt, &d.LastSyncAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan device")
			return
		}
		devices = append(devices, d)
	}

	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}

func (h *DeviceHandler) Register(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var req models.RegisterDeviceRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Platform != "macos" && req.Platform != "windows" && req.Platform != "linux" {
		writeError(w, http.StatusBadRequest, "invalid platform")
		return
	}

	if req.DeviceID != nil && *req.DeviceID != "" {
		var device models.Device
		err := h.Pool.QueryRow(r.Context(), `
			UPDATE devices
			SET device_name = CASE WHEN $3 = '' THEN device_name ELSE $3 END,
			    platform = $4
			WHERE id = $1::uuid AND user_id = $2::uuid
			RETURNING id::text, user_id::text, platform, device_name, created_at, last_sync_at`,
			*req.DeviceID, userID, req.DeviceName, req.Platform,
		).Scan(&device.ID, &device.UserID, &device.Platform, &device.DeviceName, &device.CreatedAt, &device.LastSyncAt)
		if err == nil {
			writeJSON(w, http.StatusOK, device)
			return
		}
		if err != pgx.ErrNoRows {
			writeError(w, http.StatusInternalServerError, "failed to update device")
			return
		}

		err = h.Pool.QueryRow(r.Context(), `
			INSERT INTO devices (id, user_id, platform, device_name)
			VALUES ($1::uuid, $2::uuid, $3, $4)
			RETURNING id::text, user_id::text, platform, device_name, created_at, last_sync_at`,
			*req.DeviceID, userID, req.Platform, req.DeviceName,
		).Scan(&device.ID, &device.UserID, &device.Platform, &device.DeviceName, &device.CreatedAt, &device.LastSyncAt)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to register device")
			return
		}
		writeJSON(w, http.StatusCreated, device)
		return
	}

	var device models.Device
	deviceID := newUUID()
	err := h.Pool.QueryRow(r.Context(), `
		INSERT INTO devices (id, user_id, platform, device_name)
		VALUES ($1::uuid, $2::uuid, $3, $4)
		RETURNING id::text, user_id::text, platform, device_name, created_at, last_sync_at`,
		deviceID, userID, req.Platform, req.DeviceName,
	).Scan(&device.ID, &device.UserID, &device.Platform, &device.DeviceName, &device.CreatedAt, &device.LastSyncAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to register device")
		return
	}

	writeJSON(w, http.StatusCreated, device)
}
