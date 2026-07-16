import { API_SCHEMA_VERSION } from "../../src/contracts/common.js";
import { errorResponse } from "../../src/http/errors.js";
import { requestId, requireMethod } from "../../src/http/request.js";

export async function handleHealth(request: Request): Promise<Response> {
  const id = requestId(request);
  try {
    requireMethod(request, "GET");
    return Response.json({
      status: "ok",
      api_schema_versions: [API_SCHEMA_VERSION],
      model_aliases: ["transcription-fallback-v1", "daily-entry-v1"]
    }, {
      status: 200,
      headers: {
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "X-Request-ID": id
      }
    });
  } catch (error) {
    return errorResponse(error, id);
  }
}

export default {
  fetch: handleHealth
};
