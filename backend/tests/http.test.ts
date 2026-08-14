import { describe, expect, it } from "vitest";
import { handleHealth } from "../api/v1/health.js";
import { writeSafeLog } from "../src/http/logger.js";

describe("HTTP foundation", () => {
  it("returns a content-free health response", async () => {
    const response = await handleHealth(new Request("https://lore.invalid/v1/health"));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(body).toEqual({
      status: "ok",
      api_schema_versions: ["1.0"],
      model_aliases: [
        "transcription-fallback-v1",
        "daily-entry-v1",
        "reflection-stt-v1",
        "reflection-voice-v1",
        "reflection-guide-v1",
        "reflection-entry-v1"
      ]
    });
  });

  it("rejects sensitive or unknown log fields", () => {
    expect(() => writeSafeLog({
      event: "request_started",
      request_id: "request-1",
      route: "daily_entry",
      transcript: "must not be logged"
    } as never)).toThrow();
  });

  it("writes only allowlisted operational fields", () => {
    const lines: string[] = [];
    writeSafeLog({
      event: "request_completed",
      request_id: "request-1",
      route: "health",
      status: 200,
      duration_ms: 4
    }, (line) => lines.push(line));

    expect(lines).toEqual([
      '{"event":"request_completed","request_id":"request-1","route":"health","status":200,"duration_ms":4}'
    ]);
  });
});
