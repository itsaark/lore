import { loadMaintenanceRuntimeConfig, type MaintenanceRuntimeConfig } from "../../src/config.js";
import { NeonAuthStateStore } from "../../src/auth/state-store.js";
import {
  cleanupExpiredSecurityMetadata,
  requireCronAuthorization,
  type SecurityMetadataCleanupStore
} from "../../src/maintenance/security-metadata-cleanup.js";
import { errorResponse } from "../../src/http/errors.js";
import { jsonSuccess, requestId, requireMethod } from "../../src/http/request.js";
import { API_SCHEMA_VERSION } from "../../src/contracts/common.js";

export type SecurityMetadataCleanupDependencies = {
  environment?: NodeJS.ProcessEnv;
  config?: MaintenanceRuntimeConfig;
  store?: SecurityMetadataCleanupStore;
  now?: () => Date;
};

export async function handleSecurityMetadataCleanup(
  request: Request,
  dependencies: SecurityMetadataCleanupDependencies = {}
): Promise<Response> {
  const id = requestId(request);
  try {
    requireMethod(request, "GET");
    const config = dependencies.config ?? loadMaintenanceRuntimeConfig(dependencies.environment);
    requireCronAuthorization(request, config);
    const store = dependencies.store ?? new NeonAuthStateStore(config.databaseUrl);
    const deleted = await cleanupExpiredSecurityMetadata({
      store,
      now: dependencies.now?.() ?? new Date(),
      batchSize: config.batchSize
    });
    const total = deleted.challenges + deleted.rateLimitBuckets + deleted.processingLeases;
    return jsonSuccess({
      schema_version: API_SCHEMA_VERSION,
      deleted: {
        challenges: deleted.challenges,
        rate_limit_buckets: deleted.rateLimitBuckets,
        processing_leases: deleted.processingLeases,
        total
      },
      batch_limit_per_table: config.batchSize,
      may_have_more: Object.values(deleted).some((count) => count === config.batchSize)
    }, id);
  } catch (error) {
    return errorResponse(error, id);
  }
}

export default {
  fetch: handleSecurityMetadataCleanup
};
