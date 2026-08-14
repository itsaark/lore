import { z } from "zod";

const SafeLogEventSchema = z.object({
  event: z.enum(["request_started", "request_completed", "request_failed", "provider_started", "provider_completed", "provider_failed"]),
  request_id: z.string().regex(/^[A-Za-z0-9_.:-]{1,200}$/),
  route: z.enum([
    "health",
    "transcription",
    "daily_entry",
    "reflection_credentials",
    "reflection_guide",
    "reflection_finalize"
  ]).optional(),
  status: z.number().int().min(100).max(599).optional(),
  duration_ms: z.number().int().min(0).optional(),
  error_code: z.string().regex(/^[a-z0-9_]{1,80}$/).optional(),
  provider: z.enum(["fireworks", "groq", "soniox", "deepgram", "google", "openai", "self_hosted"]).optional(),
  model_alias: z.enum([
    "transcription-fallback-v1",
    "daily-entry-v1",
    "reflection-stt-v1",
    "reflection-voice-v1",
    "reflection-guide-v1",
    "reflection-entry-v1"
  ]).optional()
}).strict();

export type SafeLogEvent = z.input<typeof SafeLogEventSchema>;

export function writeSafeLog(
  event: SafeLogEvent,
  sink: (line: string) => void = console.info
): void {
  const safeEvent = SafeLogEventSchema.parse(event);
  sink(JSON.stringify(safeEvent));
}
