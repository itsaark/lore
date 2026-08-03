import { AttestationRequestSchema } from "../../../src/contracts/auth.js";
import { makeAppAttestFlow, requireJsonBody, type AuthHandlerDependencies } from "../../../src/auth/handler.js";
import { errorResponse, LoreApiError } from "../../../src/http/errors.js";
import { jsonSuccess, requestId, requireMethod } from "../../../src/http/request.js";

export async function handleAttestation(
  request: Request,
  dependencies: AuthHandlerDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  try {
    requireMethod(request, "POST");
    const parsed = AttestationRequestSchema.safeParse(await requireJsonBody(request));
    if (!parsed.success) throw new LoreApiError("invalid_request", 400, false);
    return jsonSuccess(await makeAppAttestFlow(dependencies).attest(parsed.data), id);
  } catch (error) {
    return errorResponse(error, id);
  }
}

export default { fetch: handleAttestation };
