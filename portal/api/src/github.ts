// portal/api/src/github.ts
// Wave 7c: minimal GitHub App client used by the self-service wizard.
//
// We only need ~6 endpoints and the auth flow is simple enough that
// hand-rolling an RS256 JWT avoids pulling octokit + jsonwebtoken into
// a Linux-Consumption cold-start path.
//
// Flow:
//   1. Sign a short-lived JWT with the app private key (RS256).
//   2. Exchange it for an installation token at /app/installations/:id/access_tokens.
//      Cache the token in-process (expires in 1h; we keep it for ~50m).
//   3. Call /repos/:o/:r/... with Authorization: token <installationToken>.

import * as crypto from "node:crypto";

export interface GhRef { owner: string; repo: string; }

interface CachedInstallationToken { token: string; expiresAtMs: number; }
let cached: CachedInstallationToken | null = null;

function requiredEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`GitHub client not configured: ${name} is empty`);
  return v;
}

export function getGhRef(): GhRef {
  return { owner: requiredEnv("GITHUB_OWNER"), repo: requiredEnv("GITHUB_REPO") };
}

function b64url(buf: Buffer | string): string {
  const b = typeof buf === "string" ? Buffer.from(buf, "utf-8") : buf;
  return b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function signAppJwt(): string {
  const appId = requiredEnv("GITHUB_APP_ID");
  // Key Vault stores the PEM verbatim including newlines.
  const privateKey = requiredEnv("GITHUB_APP_PRIVATE_KEY");
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  // GitHub allows up to 10 minutes. iat=-60s protects against tiny clock skew.
  const payload = { iat: now - 60, exp: now + 9 * 60, iss: appId };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signature = crypto.sign("RSA-SHA256", Buffer.from(unsigned), privateKey);
  return `${unsigned}.${b64url(signature)}`;
}

async function fetchJson<T = unknown>(url: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(url, {
    ...init,
    headers: {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "secpulse-portal",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`GitHub ${init.method || "GET"} ${url} -> ${res.status}: ${text.slice(0, 500)}`);
  }
  return (text ? JSON.parse(text) : undefined) as T;
}

async function mintInstallationToken(): Promise<string> {
  if (cached && cached.expiresAtMs - Date.now() > 60_000) return cached.token;
  const jwt = signAppJwt();
  const installationId = requiredEnv("GITHUB_APP_INSTALLATION_ID");
  const data = await fetchJson<{ token: string; expires_at: string }>(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    { method: "POST", headers: { Authorization: `Bearer ${jwt}` } }
  );
  cached = { token: data.token, expiresAtMs: new Date(data.expires_at).getTime() };
  return data.token;
}

async function ghCall<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
  const token = await mintInstallationToken();
  return fetchJson<T>(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `token ${token}`,
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

// ---------- Contents API ----------

export interface GhContent { sha: string; content: string; encoding: string; }

export async function ghGetContent(path: string, ref = "main"): Promise<GhContent | null> {
  const { owner, repo } = getGhRef();
  try {
    return await ghCall<GhContent>("GET", `/repos/${owner}/${repo}/contents/${encodeURIComponent(path)}?ref=${encodeURIComponent(ref)}`);
  } catch (e) {
    const msg = (e as Error).message;
    if (msg.includes("-> 404")) return null;
    throw e;
  }
}

export async function ghPutContent(path: string, opts: { message: string; content: string; sha?: string; branch?: string }): Promise<{ commit: { sha: string } }> {
  const { owner, repo } = getGhRef();
  const body: Record<string, unknown> = {
    message: opts.message,
    content: Buffer.from(opts.content, "utf-8").toString("base64"),
    branch: opts.branch ?? "main",
  };
  if (opts.sha) body.sha = opts.sha;
  return ghCall<{ commit: { sha: string } }>("PUT", `/repos/${owner}/${repo}/contents/${encodeURIComponent(path)}`, body);
}

// ---------- Actions API ----------

export async function ghDispatchWorkflow(workflowFile: string, ref: string, inputs: Record<string, string>): Promise<void> {
  const { owner, repo } = getGhRef();
  await ghCall("POST", `/repos/${owner}/${repo}/actions/workflows/${encodeURIComponent(workflowFile)}/dispatches`, { ref, inputs });
}

export interface GhRun {
  id: number;
  name: string;
  display_title: string;
  status: string;                  // queued | in_progress | completed
  conclusion: string | null;       // success | failure | cancelled | ...
  html_url: string;
  created_at: string;
  updated_at: string;
  run_started_at: string;
  head_sha: string;
  event: string;
}

export async function ghListRuns(workflowFile: string, params: { since?: string; per_page?: number } = {}): Promise<GhRun[]> {
  const { owner, repo } = getGhRef();
  const qs = new URLSearchParams();
  qs.set("event", "workflow_dispatch");
  qs.set("per_page", String(params.per_page ?? 30));
  if (params.since) qs.set("created", `>=${params.since}`);
  const data = await ghCall<{ workflow_runs: GhRun[] }>("GET",
    `/repos/${owner}/${repo}/actions/workflows/${encodeURIComponent(workflowFile)}/runs?${qs.toString()}`);
  return data.workflow_runs ?? [];
}

export async function ghGetRun(runId: number): Promise<GhRun> {
  const { owner, repo } = getGhRef();
  return ghCall<GhRun>("GET", `/repos/${owner}/${repo}/actions/runs/${runId}`);
}

export interface GhJob { id: number; name: string; status: string; conclusion: string | null; html_url: string; }
export async function ghListRunJobs(runId: number): Promise<GhJob[]> {
  const { owner, repo } = getGhRef();
  const data = await ghCall<{ jobs: GhJob[] }>("GET", `/repos/${owner}/${repo}/actions/runs/${runId}/jobs`);
  return data.jobs ?? [];
}

export function isGhConfigured(): boolean {
  return Boolean(process.env.GITHUB_APP_ID && process.env.GITHUB_APP_PRIVATE_KEY && process.env.GITHUB_APP_INSTALLATION_ID && process.env.GITHUB_OWNER && process.env.GITHUB_REPO);
}
