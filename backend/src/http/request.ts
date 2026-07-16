import { LoreApiError } from "./errors.js";

export function requestId(request: Request): string {
  const incoming = request.headers.get("x-request-id");
  if (incoming && /^[A-Za-z0-9_.:-]{1,200}$/.test(incoming)) {
    return incoming;
  }
  return crypto.randomUUID();
}

export function requireMethod(request: Request, method: "GET" | "POST"): void {
  if (request.method !== method) {
    throw new LoreApiError("invalid_request", 405, false, `This endpoint requires ${method}.`);
  }
}

export function processingSignal(request: Request, timeoutMilliseconds = 55_000): AbortSignal {
  return AbortSignal.any([request.signal, AbortSignal.timeout(timeoutMilliseconds)]);
}

export function requireContentLengthBelow(request: Request, maximumBytes: number): void {
  const rawLength = request.headers.get("content-length");
  if (!rawLength) return;
  const length = Number(rawLength);
  if (!Number.isFinite(length) || length < 0) {
    throw new LoreApiError("invalid_request", 400, false);
  }
  if (length > maximumBytes) {
    throw new LoreApiError("payload_too_large", 413, false);
  }
}

export function jsonSuccess(body: unknown, id: string): Response {
  return Response.json(body, {
    status: 200,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      "X-Request-ID": id
    }
  });
}
