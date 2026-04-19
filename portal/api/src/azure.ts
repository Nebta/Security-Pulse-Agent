import { ManagedIdentityCredential, DefaultAzureCredential, type TokenCredential } from "@azure/identity";
import { BlobServiceClient } from "@azure/storage-blob";

let cred: TokenCredential | null = null;

/**
 * Use the user-assigned managed identity that's wired to the Function App at
 * deploy time. Fall back to DefaultAzureCredential locally (Azure CLI login).
 */
export function getCredential(): TokenCredential {
  if (cred) return cred;
  const clientId = process.env.PORTAL_UAMI_CLIENT_ID;
  cred = clientId
    ? new ManagedIdentityCredential({ clientId })
    : new DefaultAzureCredential();
  return cred;
}

export function getBlobClient(storageAccount: string): BlobServiceClient {
  return new BlobServiceClient(`https://${storageAccount}.blob.core.windows.net`, getCredential());
}

/**
 * Thin ARM caller. We avoid pulling @azure/arm-logic just for two endpoints
 * (run history list + trigger). Returns parsed JSON or null on 204.
 */
export async function armRequest<T>(
  method: "GET" | "POST" | "PUT" | "DELETE",
  path: string,
  body?: unknown,
  apiVersion = "2019-05-01"
): Promise<T> {
  const token = await getCredential().getToken("https://management.azure.com/.default");
  if (!token) throw new Error("Failed to acquire ARM token");
  const sep = path.includes("?") ? "&" : "?";
  const url = `https://management.azure.com${path}${sep}api-version=${apiVersion}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token.token}`,
      "Content-Type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`ARM ${method} ${url} -> ${res.status}: ${text.slice(0, 500)}`);
  }
  if (res.status === 204) return undefined as unknown as T;
  return (await res.json()) as T;
}
