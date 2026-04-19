import type { HttpRequest } from "@azure/functions";

export interface ClientPrincipal {
  identityProvider: string;
  userId: string;
  userDetails: string;            // typically the UPN
  userRoles: string[];
}

/**
 * SWA injects the authenticated user as a base64-encoded JSON object on the
 * x-ms-client-principal header before forwarding to the linked Function App.
 * Returns null when the request is unauthenticated.
 */
export function getPrincipal(req: HttpRequest): ClientPrincipal | null {
  const header = req.headers.get("x-ms-client-principal");
  if (!header) return null;
  try {
    const decoded = Buffer.from(header, "base64").toString("utf-8");
    return JSON.parse(decoded) as ClientPrincipal;
  } catch {
    return null;
  }
}

/**
 * Allowlist-based authorization for v1. PORTAL_ALLOWED_UPNS is a comma-separated
 * list of UPNs. Empty / unset = locked (no one allowed) so a misconfigured
 * deployment fails closed rather than open.
 *
 * Future iteration: per-customer Entra app roles
 * (SecPulse.<CustomerId>.Admin) checked against principal.userRoles, then
 * filter the customer list to roles the caller actually holds.
 */
export function isAuthorized(principal: ClientPrincipal | null): boolean {
  if (!principal) return false;
  const allow = (process.env.PORTAL_ALLOWED_UPNS ?? "")
    .split(",")
    .map(s => s.trim().toLowerCase())
    .filter(Boolean);
  if (allow.length === 0) return false;
  return allow.includes(principal.userDetails.toLowerCase());
}

export function getAllowedCustomers(): string[] {
  return (process.env.PORTAL_CUSTOMERS ?? "")
    .split(",")
    .map(s => s.trim())
    .filter(Boolean);
}

export interface CustomerBinding {
  id: string;
  storageAccount: string;
  resourceGroup: string;
  logicAppName: string;
  subscriptionId: string;
}

/**
 * Each customer is described in app settings as a single semicolon-separated
 * tuple, so we can scale to N customers without N*4 env vars:
 *   PORTAL_CUSTOMER_ALPLA = "stpulsealplahisxpz;rg-secpulse-alpla;la-secpulse-ALPLA;<subId>"
 */
export function getCustomerBinding(id: string): CustomerBinding | null {
  if (!getAllowedCustomers().includes(id)) return null;
  const raw = process.env[`PORTAL_CUSTOMER_${id.toUpperCase()}`];
  if (!raw) return null;
  const [storageAccount, resourceGroup, logicAppName, subscriptionId] = raw.split(";");
  if (!storageAccount || !resourceGroup || !logicAppName || !subscriptionId) return null;
  return { id, storageAccount, resourceGroup, logicAppName, subscriptionId };
}
