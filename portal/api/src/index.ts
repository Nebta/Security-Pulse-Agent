import { app, type HttpResponseInit } from "@azure/functions";
import { getPrincipal, isAuthorized, getAllowedCustomers, getCustomerBinding } from "./auth";
import { getBlobClient, armRequest } from "./azure";
import { validateConfig } from "./config-schema";

const TEMPLATES_CONTAINER = process.env.PORTAL_TEMPLATES_CONTAINER ?? "templates";

function jsonResponse(status: number, body: unknown): HttpResponseInit {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}
const unauthorized = (): HttpResponseInit => jsonResponse(401, { error: "unauthorized" });
const notFound = (what: string): HttpResponseInit => jsonResponse(404, { error: `${what} not found` });

async function readBlob(storageAccount: string, customerId: string, blobName: string): Promise<string | null> {
  const container = getBlobClient(storageAccount).getContainerClient(TEMPLATES_CONTAINER);
  const blob = container.getBlockBlobClient(`${customerId}/${blobName}`);
  if (!(await blob.exists())) return null;
  const dl = await blob.download();
  const chunks: Buffer[] = [];
  for await (const c of dl.readableStreamBody!) chunks.push(Buffer.from(c));
  return Buffer.concat(chunks).toString("utf-8");
}

async function writeJsonBlob(storageAccount: string, customerId: string, blobName: string, json: unknown): Promise<void> {
  const container = getBlobClient(storageAccount).getContainerClient(TEMPLATES_CONTAINER);
  const blob = container.getBlockBlobClient(`${customerId}/${blobName}`);
  const body = JSON.stringify(json, null, 2);
  await blob.upload(body, body.length, { blobHTTPHeaders: { blobContentType: "application/json" } });
}

// GET /api/me  -- auth probe + customer list for the SPA bootstrap.
app.http("me", {
  route: "me", methods: ["GET"], authLevel: "anonymous",
  handler: async (req) => {
    const principal = getPrincipal(req);
    if (!isAuthorized(principal)) return unauthorized();
    return jsonResponse(200, {
      user: principal!.userDetails,
      roles: principal!.userRoles,
      customers: getAllowedCustomers(),
    });
  },
});

// GET /api/customers
app.http("listCustomers", {
  route: "customers", methods: ["GET"], authLevel: "anonymous",
  handler: async (req) => {
    if (!isAuthorized(getPrincipal(req))) return unauthorized();
    return jsonResponse(200, { customers: getAllowedCustomers() });
  },
});

// GET /api/customers/{id}/config
app.http("getCustomerConfig", {
  route: "customers/{id}/config", methods: ["GET"], authLevel: "anonymous",
  handler: async (req, ctx) => {
    if (!isAuthorized(getPrincipal(req))) return unauthorized();
    const id = req.params.id;
    const binding = getCustomerBinding(id);
    if (!binding) return notFound("customer");
    const text = await readBlob(binding.storageAccount, id, "config.json");
    if (!text) return notFound("config.json");
    try { return jsonResponse(200, JSON.parse(text)); }
    catch (e) {
      ctx.error(`config.json for ${id} is not valid JSON: ${(e as Error).message}`);
      return jsonResponse(500, { error: "stored config.json is not valid JSON" });
    }
  },
});

// PUT /api/customers/{id}/config
app.http("putCustomerConfig", {
  route: "customers/{id}/config", methods: ["PUT"], authLevel: "anonymous",
  handler: async (req, ctx) => {
    const principal = getPrincipal(req);
    if (!isAuthorized(principal)) return unauthorized();
    const id = req.params.id;
    const binding = getCustomerBinding(id);
    if (!binding) return notFound("customer");
    let body: unknown;
    try { body = await req.json(); } catch { return jsonResponse(400, { error: "body must be valid JSON" }); }
    const result = validateConfig(body, id);
    if (!result.ok) return jsonResponse(400, { error: "validation failed", details: result.errors });
    await writeJsonBlob(binding.storageAccount, id, "config.json", result.value);
    ctx.log(`portal: ${principal!.userDetails} updated config for ${id}`);
    return jsonResponse(200, { ok: true });
  },
});

// GET /api/customers/{id}/runs?top=20
interface ArmRun {
  name: string;
  properties: { startTime: string; endTime?: string; status: string; error?: { code?: string; message?: string } };
}
app.http("listRuns", {
  route: "customers/{id}/runs", methods: ["GET"], authLevel: "anonymous",
  handler: async (req) => {
    if (!isAuthorized(getPrincipal(req))) return unauthorized();
    const id = req.params.id;
    const binding = getCustomerBinding(id);
    if (!binding) return notFound("customer");
    const top = Math.min(parseInt(req.query.get("top") ?? "20", 10) || 20, 100);
    const path = `/subscriptions/${binding.subscriptionId}/resourceGroups/${binding.resourceGroup}/providers/Microsoft.Logic/workflows/${binding.logicAppName}/runs?$top=${top}`;
    const data = await armRequest<{ value: ArmRun[] }>("GET", path);
    return jsonResponse(200, {
      runs: (data.value ?? []).map(r => ({
        id: r.name,
        startTime: r.properties.startTime,
        endTime: r.properties.endTime,
        status: r.properties.status,
        errorCode: r.properties.error?.code,
        errorMessage: r.properties.error?.message,
      })),
    });
  },
});

// POST /api/customers/{id}/trigger -- fires manual trigger via ARM so the
// callback URL never reaches the browser.
app.http("triggerRun", {
  route: "customers/{id}/trigger", methods: ["POST"], authLevel: "anonymous",
  handler: async (req, ctx) => {
    const principal = getPrincipal(req);
    if (!isAuthorized(principal)) return unauthorized();
    const id = req.params.id;
    const binding = getCustomerBinding(id);
    if (!binding) return notFound("customer");
    const path = `/subscriptions/${binding.subscriptionId}/resourceGroups/${binding.resourceGroup}/providers/Microsoft.Logic/workflows/${binding.logicAppName}/triggers/manual/run`;
    await armRequest("POST", path, undefined, "2016-06-01");
    ctx.log(`portal: ${principal!.userDetails} triggered ad-hoc run for ${id}`);
    return jsonResponse(202, { ok: true });
  },
});
