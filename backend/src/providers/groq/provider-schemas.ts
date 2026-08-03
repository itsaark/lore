import { z } from "zod";

export const GroqTranscriptionSchema = z.object({
  text: z.string(),
  language: z.string().nullable().optional(),
  duration: z.number().nonnegative().optional(),
  segments: z.array(z.object({
    id: z.union([z.number().int(), z.string()]).optional(),
    start: z.number().nonnegative(),
    end: z.number().nonnegative(),
    text: z.string(),
    avg_logprob: z.number().optional(),
    no_speech_prob: z.number().optional()
  }).passthrough().superRefine((segment, context) => {
    if (segment.end < segment.start) {
      context.addIssue({ code: "custom", path: ["end"], message: "end must not precede start" });
    }
  })).optional(),
  x_groq: z.object({ id: z.string().min(1) }).passthrough().optional()
}).passthrough();
