export type Env = Cloudflare.Env & {
  TOKEN_HASH_KEY: string;
};

export interface ServiceLimits {
  minimumSyncIntervalSeconds: number;
  dailySyncLimit: number;
  maximumDevicesPerVault: number;
}

export function limits(env: Env): ServiceLimits {
  return {
    minimumSyncIntervalSeconds: boundedInteger(env.MIN_SYNC_INTERVAL_SECONDS, 3_600, 0, 86_400),
    dailySyncLimit: boundedInteger(env.DAILY_SYNC_LIMIT, 8, 0, 100),
    // The D1 migration enforces this same product invariant at the write point
    // so concurrent recovery/pairing requests cannot race past the limit.
    maximumDevicesPerVault: 5,
  };
}

export function syncEnabled(env: Env): boolean {
  return (env.SYNC_ENABLED ?? "true").toLowerCase() !== "false";
}

export function hourlyRateLimitsEnabled(env: Env): boolean {
  return (env.HOURLY_RATE_LIMITS_ENABLED ?? "true").toLowerCase() !== "false";
}

function boundedInteger(raw: string | undefined, fallback: number, minimum: number, maximum: number): number {
  if (!raw) return fallback;
  const parsed = Number(raw);
  return Number.isInteger(parsed) && parsed >= minimum && parsed <= maximum ? parsed : fallback;
}
