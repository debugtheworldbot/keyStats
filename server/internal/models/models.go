package models

import (
	"encoding/json"
	"time"
)

type User struct {
	ID           string    `json:"id"`
	Username     string    `json:"username"`
	PasswordHash string    `json:"-"`
	CreatedAt    time.Time `json:"created_at"`
}

type Device struct {
	ID         string     `json:"id"`
	UserID     string     `json:"user_id"`
	Platform   string     `json:"platform"`
	DeviceName string     `json:"device_name"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSyncAt *time.Time `json:"last_sync_at,omitempty"`
}

// DailyStatsPayload mirrors the client DailyStats JSON.
// Privacy: aggregate counters only; key_press_counts maps key names to counts.
type DailyStatsPayload struct {
	Date              string         `json:"date"`
	KeyPresses        int            `json:"keyPresses"`
	KeyPressCounts    map[string]int `json:"keyPressCounts,omitempty"`
	LeftClicks        int            `json:"leftClicks"`
	RightClicks       int            `json:"rightClicks"`
	SideBackClicks    int            `json:"sideBackClicks"`
	SideForwardClicks int            `json:"sideForwardClicks"`
	MouseDistance     float64        `json:"mouseDistance"`
	ScrollDistance    float64        `json:"scrollDistance"`
	PeakKPS           int            `json:"peakKPS"`
	PeakCPS           int            `json:"peakCPS"`
	AppStats          json.RawMessage `json:"appStats,omitempty"`
}

type UpsertStatsRequest struct {
	DeviceID string            `json:"device_id"`
	Date     string            `json:"date"`
	Version  int64             `json:"version"`
	Stats    DailyStatsPayload `json:"stats"`
}

type BulkUpsertStatsRequest struct {
	DeviceID string              `json:"device_id"`
	Records  []UpsertStatsRecord `json:"records"`
}

type UpsertStatsRecord struct {
	Date    string            `json:"date"`
	Version int64             `json:"version"`
	Stats   DailyStatsPayload `json:"stats"`
}

type StatsRecordResponse struct {
	DeviceID   string            `json:"device_id"`
	Platform   string            `json:"platform"`
	DeviceName string            `json:"device_name"`
	Date       string            `json:"date"`
	Version    int64             `json:"version"`
	UpdatedAt  time.Time         `json:"updated_at"`
	Stats      DailyStatsPayload `json:"stats"`
}

type RegisterDeviceRequest struct {
	DeviceID   *string `json:"device_id,omitempty"`
	Platform   string  `json:"platform"`
	DeviceName string  `json:"device_name"`
}

type AuthRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type AuthResponse struct {
	Token  string `json:"token"`
	UserID string `json:"user_id"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}
