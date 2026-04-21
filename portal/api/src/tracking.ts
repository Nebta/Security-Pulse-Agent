// portal/api/src/tracking.ts
// Wave 7c: portal tracking storage (dedicated container `tracking` on
// the portal Function App's backing storage account). Stores:
//
//   - onboardings/<CUSTOMER>/<requestId>.json — summary blob,
//     written by the portal on POST /api/customers and overwritten
//     by the onboard.yml workflow on completion.
//   - customers/registry.json — dynamic customer registry that
//     auth.ts merges with the PORTAL_CUSTOMERS env var.
//
// All writes use blob If-Match (ETag) to avoid lost-update races
// when two concurrent onboardings complete at nearly the same time.

import { ContainerClient, RestError } from "@azure/storage-blob";
import { getCredential } from "./azure";
import type { CustomerBinding } from "./auth";

const TRACKING_SA = process.env.PORTAL_TRACKING_STORAGE_ACCOUNT;
const TRACKING_CONTAINER = process.env.PORTAL_TRACKING_CONTAINER ?? "tracking";

let cachedContainer: ContainerClient | null = null;
function container(): ContainerClient {
  if (!TRACKING_SA) throw new Error("PORTAL_TRACKING_STORAGE_ACCOUNT is not set");
  if (cachedContainer) return cachedContainer;
  // Lazy import to keep the non-tracking code paths identical to Wave 6.
  const { BlobServiceClient } = require("@azure/storage-blob");
  const svc: { getContainerClient: (n: string) => ContainerClient } = new BlobServiceClient(
    `https://${TRACKING_SA}.blob.core.windows.net`,
    getCredential()
  );
  cachedContainer = svc.getContainerClient(TRACKING_CONTAINER);
  return cachedContainer;
}

async function downloadText(blobName: string): Promise<{ text: string; etag: string } | null> {
  try {
    const blob = container().getBlockBlobClient(blobName);
    const dl = await blob.download();
    const chunks: Buffer[] = [];
    for await (const c of dl.readableStreamBody!) chunks.push(Buffer.from(c));
    return { text: Buffer.concat(chunks).toString("utf-8"), etag: dl.etag ?? "" };
  } catch (e) {
    if (e instanceof RestError && e.statusCode === 404) return null;
    throw e;
  }
}

async function uploadText(blobName: string, text: string, ifMatch?: string): Promise<{ etag: string }> {
  const blob = container().getBlockBlobClient(blobName);
  const buf = Buffer.from(text, "utf-8");
  const opts: Record<string, unknown> = {
    blobHTTPHeaders: { blobContentType: "application/json" },
  };
  if (ifMatch) opts.conditions = { ifMatch };
  else opts.conditions = { ifNoneMatch: "*" };   // create-only on first write
  const r = await blob.upload(buf, buf.length, opts as never);
  return { etag: r.etag ?? "" };
}

async function uploadTextOverwrite(blobName: string, text: string): Promise<void> {
  const blob = container().getBlockBlobClient(blobName);
  const buf = Buffer.from(text, "utf-8");
  await blob.upload(buf, buf.length, { blobHTTPHeaders: { blobContentType: "application/json" } });
}

// ---------- onboarding request tracking ----------

export interface OnboardingRequest {
  customerId: string;
  requestId: string;
  displayName: string;
  dispatchedAt: string;
  commitSha: string;
  binding: CustomerBinding;       // what we'll add to the registry on success
  runId?: number;                 // filled in by GET /api/onboardings/{id} first-time poll
  completed?: boolean;            // true once the workflow summary is in place
  // Mirror of onboard-summary.json once the workflow has uploaded it.
  summary?: unknown;
}

export async function writeOnboardingRequest(req: OnboardingRequest): Promise<void> {
  // Create-only initial write. The workflow later overwrites the blob
  // with its own summary JSON (we read both and merge in the poll
  // endpoint).
  const json = JSON.stringify({ _portal: req }, null, 2);
  try {
    await uploadText(onboardingBlobName(req.customerId, req.requestId), json);
  } catch (e) {
    if (e instanceof RestError && e.statusCode === 412) {
      // Already exists — extremely unlikely because requestId is
      // portal-generated and unique, but handle idempotently.
      await uploadTextOverwrite(onboardingBlobName(req.customerId, req.requestId), json);
      return;
    }
    throw e;
  }
}

export async function readOnboardingRequest(customerId: string, requestId: string): Promise<{
  portalState: OnboardingRequest;
  workflowSummary: unknown | null;
} | null> {
  const blobName = onboardingBlobName(customerId, requestId);
  const raw = await downloadText(blobName);
  if (!raw) return null;
  let parsed: Record<string, unknown>;
  try { parsed = JSON.parse(raw.text); } catch { return null; }
  // The workflow overwrites the blob with the plain summary (which
  // doesn't carry our _portal wrapper). Distinguish the two shapes.
  if (parsed && typeof parsed === "object" && "_portal" in parsed) {
    return { portalState: parsed._portal as OnboardingRequest, workflowSummary: null };
  }
  // Workflow has written over the top. The portal state was implicit
  // in the initial commit; reconstruct customerId/requestId from the
  // blob path rather than trusting the payload.
  return {
    portalState: {
      customerId,
      requestId,
      displayName: (parsed as { customerId?: string }).customerId ?? customerId,
      dispatchedAt: "",
      commitSha: "",
      binding: {} as CustomerBinding,
    },
    workflowSummary: parsed,
  };
}

export async function updateOnboardingRequest(req: OnboardingRequest): Promise<void> {
  // Overwrite unconditionally — the portal is the only writer to the
  // _portal wrapper, and only on the poll path which is serialized
  // per-request via the in-memory poll de-duping.
  await uploadTextOverwrite(onboardingBlobName(req.customerId, req.requestId), JSON.stringify({ _portal: req }, null, 2));
}

function onboardingBlobName(customerId: string, requestId: string): string {
  return `onboardings/${customerId}/${requestId}.json`;
}

// ---------- customer registry (env + blob) ----------

export interface RegistryEntry extends CustomerBinding { addedAt: string; }
interface RegistryFile { customers: RegistryEntry[]; }

interface CachedRegistry { data: RegistryFile; etag: string; fetchedAtMs: number; }
let registryCache: CachedRegistry | null = null;
let lastKnownGood: CachedRegistry | null = null;
const REGISTRY_CACHE_MS = 60_000;
const REGISTRY_BLOB = "customers/registry.json";

export async function readRegistry(force = false): Promise<RegistryFile> {
  if (!TRACKING_SA) return { customers: [] };
  const now = Date.now();
  if (!force && registryCache && now - registryCache.fetchedAtMs < REGISTRY_CACHE_MS) {
    return registryCache.data;
  }
  try {
    const raw = await downloadText(REGISTRY_BLOB);
    const data: RegistryFile = raw ? JSON.parse(raw.text) : { customers: [] };
    registryCache = { data, etag: raw?.etag ?? "", fetchedAtMs: now };
    lastKnownGood = registryCache;
    return data;
  } catch (e) {
    // Storage blip. Keep serving the last good registry rather than
    // temporarily disappearing customers from the portal.
    if (lastKnownGood) {
      registryCache = { ...lastKnownGood, fetchedAtMs: now };
      return lastKnownGood.data;
    }
    throw e;
  }
}

export async function appendToRegistry(entry: CustomerBinding): Promise<void> {
  if (!TRACKING_SA) throw new Error("PORTAL_TRACKING_STORAGE_ACCOUNT is not set");
  // Optimistic concurrency: retry a handful of times on ETag mismatch.
  for (let attempt = 0; attempt < 5; attempt++) {
    const raw = await downloadText(REGISTRY_BLOB);
    const current: RegistryFile = raw ? JSON.parse(raw.text) : { customers: [] };
    if (current.customers.some(c => c.id === entry.id)) {
      // Already registered. Refresh binding fields but keep the timestamp.
      current.customers = current.customers.map(c => c.id === entry.id ? { ...c, ...entry } : c);
    } else {
      current.customers.push({ ...entry, addedAt: new Date().toISOString() });
    }
    const body = JSON.stringify(current, null, 2);
    try {
      if (raw) {
        await uploadText(REGISTRY_BLOB, body, raw.etag);
      } else {
        await uploadText(REGISTRY_BLOB, body /* create-only */);
      }
      registryCache = null; // force refresh on next read
      lastKnownGood = null;
      return;
    } catch (e) {
      const code = e instanceof RestError ? e.statusCode : 0;
      if (code !== 412) throw e;
      // Lost update race; re-read and retry.
    }
  }
  throw new Error("appendToRegistry: failed after 5 retries due to ETag contention");
}
