import { loadAppAttestRuntimeConfig } from "../../../src/config.js";
import { ChallengeRequestSchema } from "../../../src/contracts/auth.js";
import { makeAppAttestFlow, rateLimitIdentity, requireJsonBody, type AuthHandlerDependencies } from "../../../src/auth/handler.js";
import { errorResponse, LoreApiError } from "../../../src/http/errors.js";
import { jsonSuccess, requestId, requireMethod } from "../../../src/http/request.js";

export async function handleChallenge(
  request: Request,
  dependencies: AuthHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  try {
    requireMethod(request, "POST");
    const parsed = ChallengeRequestSchema.safeParse(await requireJsonBody(request, 2_048));
    if (!parsed.success) throw new LoreApiError("invalid_request", 400, false);
    const config = dependencies.config ?? loadAppAttestRuntimeConfig(dependencies.environment);
    const flow = makeAppAttestFlow({ ...dependencies, config });
    const response = await flow.issueChallenge({
      purpose: parsed.data.purpose,
      keyId: parsed.data.key_id,
      rateLimitIdentity: rateLimitIdentity(request, config)
    });
    return jsonSuccess(response, id);
  } catch (error) {
    return errorResponse(error, id);
  }
}

export default { fetch: handleChallenge };
