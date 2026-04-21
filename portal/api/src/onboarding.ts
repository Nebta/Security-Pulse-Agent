// portal/api/src/onboarding.ts
// Wave 7c: wizard endpoints.
//
//   POST /api/scrape                 — best-effort brand extraction from a URL.
//   POST /api/customers              — commit params file + dispatch onboard.yml.
//   GET  /api/onboardings/{id}/{req} — poll the status of a specific request.

import { app, type HttpRequest, type HttpResponseInit } from "@azure/functions";
import { getPrincipal, isAuthorized, getCustomerBinding } from "./auth";
import { ghDispatchWorkflow, ghGetContent, ghListRunJobs, ghListRuns, ghPutContent, isGhConfigured, type GhRun } from "./github";
import { scrapeUrl } from "./scrape";
import { appendToRegistry, readOnboardingRequest, writeOnboardingRequest, type OnboardingRequest } from "./tracking";
import * as crypto from "node:crypto";

const json = (status: number, body: unknown): HttpResponseInit => ({
  status,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});
const unauthorized = (): HttpResponseInit => json(401, { error: "unauthorized" });
const CUSTOMER_ID_RE = /^[A-Z][A-Z0-9]{1,19}$/;
const WORKFLOW_FILE = "onboard.yml";
const DEFAULT_WORKSPACE = process.env.PORTAL_DEFAULT_WORKSPACE_RESOURCE_ID ?? "";

// -------------------- POST /api/scrape --------------------
app.http("scrape", {
  route: "scrape", methods: ["POST"], authLevel: "anonymous",
  handler: async (req: HttpRequest) => {
    if (!isAuthorized(getPrincipal(req))) return unauthorized();
    let body: { url?: string };
    try { body = await req.json() as { url?: string }; } catch { return json(400, { error: "body must be JSON" }); }
    if (!body.url) return json(400, { error: "url is required" });
    try {
      const result = await scrapeUrl(body.url);
      return json(200, result);
    } catch (e) {
      return json(400, { error: (e as Error).message });
    }
  },
});

// -------------------- POST /api/customers --------------------
interface CreateCustomerBody {
  customerId?: string;
  displayName?: string;
  recipientEmail?: string;
  senderMailbox?: string;
  primaryColor?: string;
  skipGraphPerms?: boolean;
}

function validateBody(b: CreateCustomerBody): string[] {
  const errs: string[] = [];
  if (!b.customerId || !CUSTOMER_ID_RE.test(b.customerId)) errs.push("customerId must match ^[A-Z][A-Z0-9]{1,19}$");
  if (!b.displayName || b.displayName.length < 2 || b.displayName.length > 80) errs.push("displayName must be 2-80 chars");
  if (!b.recipientEmail || !/.+@.+\..+/.test(b.recipientEmail)) errs.push("recipientEmail is required");
  if (!b.senderMailbox || !/.+@.+\..+/.test(b.senderMailbox)) errs.push("senderMailbox is required");
  return errs;
}

function buildParamsJson(b: Required<Pick<CreateCustomerBody, "customerId" | "recipientEmail" | "senderMailbox">>): string {
  const id = b.customerId;
  return JSON.stringify({
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    contentVersion: "1.0.0.0",
    parameters: {
      location:                            { value: "westeurope" },
      resourceGroupName:                   { value: `rg-secpulse-${id.toLowerCase()}` },
      customerId:                          { value: id },
      recipientEmail:                      { value: b.recipientEmail },
      senderMailbox:                       { value: b.senderMailbox },
      scheduleHour:                        { value: 7 },
      scheduleTimeZone:                    { value: "W. Europe Standard Time" },
      sentinelWorkspaceResourceId:         { value: DEFAULT_WORKSPACE },
      estimatedPricePerGb:                 { value: "2.30" },
      currencyCode:                        { value: "EUR" },
      existingTemplatesStorageAccountName: { value: "" },
    },
  }, null, 2) + "\n";
}

app.http("createCustomer", {
  route: "customers", methods: ["POST"], authLevel: "anonymous",
  handler: async (req, ctx) => {
    const principal = getPrincipal(req);
    if (!isAuthorized(principal)) return unauthorized();
    if (!isGhConfigured()) return json(500, { error: "GitHub App not configured (see docs/GITHUB-APP-SETUP.md)" });
    if (!DEFAULT_WORKSPACE) return json(500, { error: "PORTAL_DEFAULT_WORKSPACE_RESOURCE_ID is not set" });

    let body: CreateCustomerBody;
    try { body = await req.json() as CreateCustomerBody; } catch { return json(400, { error: "body must be JSON" }); }
    const errs = validateBody(body);
    if (errs.length) return json(400, { error: "validation failed", details: errs });

    const customerId = body.customerId!;
    const paramsPath = `infra/customers/${customerId}.parameters.json`;

    // Bail if the params file already exists on main (avoid clobbering).
    const existing = await ghGetContent(paramsPath, "main");
    if (existing) return json(409, { error: `${paramsPath} already exists; pick a different customer id or delete the file first` });

    const requestId = `req-${Date.now().toString(36)}-${crypto.randomBytes(4).toString("hex")}`;
    const paramsJson = buildParamsJson({
      customerId,
      recipientEmail: body.recipientEmail!,
      senderMailbox: body.senderMailbox!,
    });

    // Commit the params file.
    let commitSha: string;
    try {
      const r = await ghPutContent(paramsPath, {
        message: `wave7c: onboard ${customerId} via portal wizard (${requestId})`,
        content: paramsJson,
      });
      commitSha = r.commit.sha;
    } catch (e) {
      return json(502, { error: "failed to commit params file", detail: (e as Error).message });
    }

    // Record the pending onboarding before dispatch, so a
    // dispatch-failure path still leaves a breadcrumb we can surface.
    const binding = {
      id: customerId,
      // storageAccount is discovered by the workflow; populate on first successful poll.
      storageAccount: "",
      resourceGroup: `rg-secpulse-${customerId.toLowerCase()}`,
      logicAppName: `la-secpulse-${customerId}`,
      subscriptionId: "",
    };
    const record: OnboardingRequest = {
      customerId,
      requestId,
      displayName: body.displayName!,
      dispatchedAt: new Date().toISOString(),
      commitSha,
      binding,
    };
    try { await writeOnboardingRequest(record); }
    catch (e) { ctx.error(`failed to write onboarding tracking blob: ${(e as Error).message}`); }

    // Dispatch the workflow.
    try {
      await ghDispatchWorkflow(WORKFLOW_FILE, "main", {
        customer: customerId,
        request_id: requestId,
        skip_graph_perms: body.skipGraphPerms ? "true" : "false",
      });
    } catch (e) {
      return json(502, {
        error: "committed params file but failed to dispatch workflow",
        detail: (e as Error).message,
        commitSha,
        recoveryHint: `An operator can still trigger the run manually: gh workflow run ${WORKFLOW_FILE} -f customer=${customerId} -f request_id=${requestId}`,
      });
    }

    ctx.log(`portal wizard: ${principal!.userDetails} dispatched onboard for ${customerId} req=${requestId}`);
    return json(202, {
      ok: true,
      customerId,
      requestId,
      commitSha,
      pollUrl: `/api/onboardings/${customerId}/${requestId}`,
    });
  },
});

// -------------------- GET /api/onboardings/{id}/{requestId} --------------------

app.http("getOnboarding", {
  route: "onboardings/{id}/{requestId}", methods: ["GET"], authLevel: "anonymous",
  handler: async (req, ctx) => {
    if (!isAuthorized(getPrincipal(req))) return unauthorized();
    const customerId = req.params.id;
    const requestId = req.params.requestId;
    if (!CUSTOMER_ID_RE.test(customerId) || !/^req-[a-z0-9-]{5,60}$/.test(requestId)) return json(400, { error: "bad id format" });

    const stored = await readOnboardingRequest(customerId, requestId);
    if (!stored) return json(404, { error: "onboarding not found" });
    const portalState = stored.portalState;

    // If the workflow has uploaded its final summary, we can return a
    // completed result without another GitHub API round-trip.
    if (stored.workflowSummary) {
      const s = stored.workflowSummary as { status?: string; storageAccount?: string; logicAppName?: string; resourceGroup?: string; subscriptionId?: string; manualSteps?: unknown[] };
      const registered = await maybeRegister(portalState, s, ctx);
      return json(200, {
        status: "completed",
        conclusion: mapSummaryToConclusion(s.status),
        runUrl: null,
        startedAt: portalState.dispatchedAt,
        completedAt: null,
        summary: s,
        registered,
        portalState,
      });
    }

    // If portalState.runId was cached (legacy blobs), try it first.
    let run: GhRun | null = null;
    if (portalState.runId) {
      try { run = (await ghListRuns(WORKFLOW_FILE, { per_page: 30 })).find(r => r.id === portalState.runId) ?? null; }
      catch { run = null; }
    }
    if (!run) {
      try {
        const recent = await ghListRuns(WORKFLOW_FILE, { per_page: 30 });
        run = recent.find(r => r.display_title?.includes(`(${requestId})`)) ?? null;
        // Deliberately NOT persisting runId back to the tracking blob:
        // the workflow may race with us and upload its final summary
        // between our read and write, which would clobber it.
        // Re-finding by display_title is cheap and deterministic.
      } catch (e) {
        ctx.warn(`GitHub API listRuns failed: ${(e as Error).message}`);
      }
    }

    let jobs: { name: string; status: string; conclusion: string | null }[] = [];
    if (run) {
      try {
        jobs = (await ghListRunJobs(run.id)).map(j => ({ name: j.name, status: j.status, conclusion: j.conclusion }));
      } catch {}
    }

    return json(200, {
      status: run?.status ?? "queued",
      conclusion: run?.conclusion ?? null,
      runUrl: run?.html_url ?? null,
      startedAt: run?.run_started_at ?? portalState.dispatchedAt,
      completedAt: run?.status === "completed" ? run.updated_at : null,
      jobs,
      summary: null,
      portalState,
    });
  },
});

function mapSummaryToConclusion(status: string | undefined): string {
  switch (status) {
    case "succeeded": case "succeeded-with-manual-steps": return "success";
    case "succeeded-with-errors": return "success_with_errors";
    case "failed": return "failure";
    default: return "unknown";
  }
}

async function maybeRegister(
  portalState: OnboardingRequest,
  summary: { status?: string; storageAccount?: string; logicAppName?: string; resourceGroup?: string; subscriptionId?: string },
  ctx: { log: (m: string) => void; warn: (m: string) => void }
): Promise<boolean> {
  if (summary.status !== "succeeded" && summary.status !== "succeeded-with-manual-steps") return false;
  if (!summary.storageAccount || !summary.subscriptionId || !summary.resourceGroup || !summary.logicAppName) {
    ctx.warn(`skipping registry update for ${portalState.customerId}: summary is missing required binding fields`);
    return false;
  }
  try {
    await appendToRegistry({
      id: portalState.customerId,
      storageAccount: summary.storageAccount,
      resourceGroup: summary.resourceGroup,
      logicAppName: summary.logicAppName,
      subscriptionId: summary.subscriptionId,
    });
    ctx.log(`registry: ${portalState.customerId} registered`);
    return true;
  } catch (e) {
    ctx.warn(`registry append failed for ${portalState.customerId}: ${(e as Error).message}`);
    return false;
  }
}
