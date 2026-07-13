package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"

	"keystats-server/internal/config"
	"keystats-server/internal/db"
	"keystats-server/internal/handlers"
	appmw "keystats-server/internal/middleware"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	ctx := context.Background()
	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer pool.Close()

	if err := db.RunMigrations(ctx, pool, cfg.MigrationsDir); err != nil {
		log.Fatalf("migrations: %v", err)
	}

	authHandler := &handlers.AuthHandler{
		Pool:      pool,
		JWTSecret: cfg.JWTSecret,
		JWTExp:    cfg.JWTExpiration,
	}
	deviceHandler := &handlers.DeviceHandler{Pool: pool}
	syncHandler := &handlers.SyncHandler{Pool: pool}

	r := chi.NewRouter()
	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)
	r.Use(chimw.Timeout(60 * time.Second))

	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	r.Route("/api/v1", func(api chi.Router) {
		api.Post("/auth/register", authHandler.Register)
		api.Post("/auth/login", authHandler.Login)

		api.Group(func(protected chi.Router) {
			protected.Use(appmw.Auth(cfg.JWTSecret))
			protected.Get("/devices", deviceHandler.List)
			protected.Post("/devices", deviceHandler.Register)
			protected.Put("/sync/stats", syncHandler.Upsert)
			protected.Post("/sync/stats/bulk", syncHandler.BulkUpsert)
			protected.Get("/sync/stats", syncHandler.List)
		})
	})

	server := &http.Server{
		Addr:              cfg.Addr,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("KeyStats sync server listening on %s", cfg.Addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}
