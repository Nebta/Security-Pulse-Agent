// Stub: returns a placeholder customer config. The real implementation
// will read config.json from the customer's blob container, gated by
// the SWA auth role 'customerAdmin' + a customerId-claim match.
//
// Wave 6 — scaffold only, not deployed.

import type { Context, HttpRequest } from "@azure/functions";

export default async function (
  context: Context,
  req: HttpRequest
): Promise<void> {
  const customerId = (context.bindingData?.customerId as string) ?? "";
  const principal = parseClientPrincipal(req);

  if (!principal) {
    context.res = { status: 401, body: { error: "not_authenticated" } };
    return;
  }
  if (!isAdminFor(principal, customerId)) {
    context.res = { status: 403, body: { error: "forbidden" } };
    return;
  }

  // TODO: read config.json from the per-customer storage account using
  // the portal UAMI (DefaultAzureCredential), scoped by customerId.
  context.res = {
    status: 200,
    headers: { "content-type": "application/json" },
    body: {
      customerId,
      _stub: true,
      sectionsEnabled: {
        vulnerabilities: true,
        threatLandscape: true,
        mdtiHighlights: true,
        openIncidents: true,
        riskyUsers: true,
        entraIdProtection: true,
        intuneCompliance: true,
        sentinelCost: true,
      },
    },
  };
}

interface ClientPrincipal {
  identityProvider: string;
  userId: string;
  userDetails: string;
  userRoles: string[];
}

function parseClientPrincipal(req: HttpRequest): ClientPrincipal | null {
  const header = req.headers["x-ms-client-principal"];
  if (!header) return null;
  try {
    const json = Buffer.from(header, "base64").toString("utf8");
    return JSON.parse(json) as ClientPrincipal;
  } catch {
    return null;
  }
}

function isAdminFor(principal: ClientPrincipal, customerId: string): boolean {
  if (!customerId) return false;
  return principal.userRoles.includes(`SecPulse.${customerId}.Admin`);
}
