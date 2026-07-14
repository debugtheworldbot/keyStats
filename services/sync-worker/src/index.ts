import { runCleanup } from "./cleanup";
import type { Env } from "./env";
import { ApiError, json } from "./http";
import { route } from "./routes";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const requestId = crypto.randomUUID();
    try {
      if (!env.TOKEN_HASH_KEY || env.TOKEN_HASH_KEY.length < 32) {
        throw new Error("TOKEN_HASH_KEY is not configured");
      }
      const response = await route(request, env);
      return withSecurityHeaders(response, requestId);
    } catch (error) {
      if (error instanceof ApiError) {
        return withSecurityHeaders(json(
          { code: error.code, message: error.message, ...error.details, requestId },
          error.status,
          error.headers,
        ), requestId);
      }
      return withSecurityHeaders(json(
        { code: "internal_error", message: "The sync service could not complete the request", requestId },
        500,
      ), requestId);
    }
  },

  async scheduled(_controller: ScheduledController, env: Env, context: ExecutionContext): Promise<void> {
    context.waitUntil(runCleanup(env));
  },
} satisfies ExportedHandler<Env>;

function withSecurityHeaders(response: Response, requestId: string): Response {
  const headers = new Headers(response.headers);
  headers.set("x-content-type-options", "nosniff");
  headers.set("referrer-policy", "no-referrer");
  headers.set("x-request-id", requestId);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
