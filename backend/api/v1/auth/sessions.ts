import { SessionRequestSchema } from "../../../src/contracts/auth.js";
import { makeAppAttestFlow, requireJsonBody, type AuthHandlerDependencies } from "../../../src/auth/handler.js";
import { errorResponse, LoreApiError } from "../../../src/http/errors.js";
import { jsonSuccess, requestId, requireMethod } from "../../../src/http/request.js";

export async function handleSession(
  request: Request,
  dependencies: AuthHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  try {
    requireMethod(request, "POST");
    const parsed = SessionRequestSchema.safeParse(await requireJsonBody(request));
    if (!parsed.success) throw new LoreApiError("invalid_request", 400, false);
    return jsonSuccess(await makeAppAttestFlow(dependencies).createSession(parsed.data), id);
  } catch (error) {
    return errorResponse(error, id);
  }
}

export default { fetch: handleSession };
