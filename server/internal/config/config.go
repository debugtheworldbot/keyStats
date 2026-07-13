package config

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	Addr          string
	DatabaseURL   string
	JWTSecret     string
	JWTExpiration time.Duration
	MigrationsDir string
}

func Load() (Config, error) {
	loadDotEnv()

	cfg := Config{
		Addr:          envOrDefault("ADDR", ":8080"),
		DatabaseURL:   os.Getenv("DATABASE_URL"),
		JWTSecret:     os.Getenv("JWT_SECRET"),
		MigrationsDir: envOrDefault("MIGRATIONS_DIR", "migrations"),
	}

	exp := envOrDefault("JWT_EXPIRATION", "720h")
	d, err := time.ParseDuration(exp)
	if err != nil {
		return Config{}, fmt.Errorf("invalid JWT_EXPIRATION: %w", err)
	}
	cfg.JWTExpiration = d

	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSecret == "" {
		return Config{}, fmt.Errorf("JWT_SECRET is required")
	}
	return cfg, nil
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// loadDotEnv reads server/.env when present. Existing shell env vars take precedence.
func loadDotEnv() {
	paths := []string{".env"}
	if exe, err := os.Executable(); err == nil {
		paths = append(paths, filepath.Join(filepath.Dir(exe), ".env"))
	}
	for _, path := range paths {
		if err := parseDotEnvFile(path); err == nil {
			return
		}
	}
}

func parseDotEnvFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		if key == "" {
			continue
		}
		if os.Getenv(key) == "" {
			_ = os.Setenv(key, value)
		}
	}
	return scanner.Err()
}
