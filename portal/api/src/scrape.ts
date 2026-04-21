// portal/api/src/scrape.ts
// Wave 7c: server-side URL fetch that extracts brand metadata for the
// onboarding wizard. Defence in depth against SSRF because the callers
// are authenticated but outbound reachability is the dangerous bit.

import { lookup as dnsLookup } from "node:dns/promises";
import * as net from "node:net";

const MAX_BYTES = 2 * 1024 * 1024;
const TIMEOUT_MS = 5_000;
const MAX_REDIRECTS = 3;

export interface ScrapeResult {
  title: string | null;
  displayName: string | null;
  suggestedCustomerId: string | null;
  primaryColor: string | null;
  faviconDataUrl: string | null;
  imageUrl: string | null;
  finalUrl: string;
}

function isPrivateIp(ip: string): boolean {
  if (!net.isIP(ip)) return true;       // unknown family? treat as hostile
  if (net.isIPv4(ip)) {
    const parts = ip.split(".").map(n => parseInt(n, 10));
    if (parts[0] === 10) return true;
    if (parts[0] === 127) return true;
    if (parts[0] === 0) return true;
    if (parts[0] === 169 && parts[1] === 254) return true;  // link-local + Azure IMDS (169.254.169.254)
    if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true;
    if (parts[0] === 192 && parts[1] === 168) return true;
    if (parts[0] >= 224) return true;   // multicast + reserved
    return false;
  }
  // IPv6
  const lower = ip.toLowerCase();
  if (lower === "::1" || lower === "::") return true;
  if (lower.startsWith("fe80:")) return true;                // link-local
  if (lower.startsWith("fc") || lower.startsWith("fd")) return true;  // ULA
  // IPv4-mapped (::ffff:a.b.c.d)
  const m = lower.match(/^::ffff:([0-9.]+)$/);
  if (m) return isPrivateIp(m[1]);
  return false;
}

async function assertPublicUrl(url: URL): Promise<void> {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Only http/https URLs are allowed");
  }
  if (net.isIP(url.hostname)) {
    throw new Error("Bare IP addresses are not allowed");
  }
  const results = await dnsLookup(url.hostname, { all: true });
  if (results.length === 0) throw new Error(`DNS lookup returned no records for ${url.hostname}`);
  for (const r of results) {
    if (isPrivateIp(r.address)) {
      throw new Error(`Refusing to fetch ${url.hostname}: resolves to private/reserved IP ${r.address}`);
    }
  }
}

async function fetchWithLimits(url: URL, acceptedTypes: string[]): Promise<{ bodyBuf: Buffer; contentType: string; finalUrl: URL }> {
  let current = url;
  for (let hops = 0; hops <= MAX_REDIRECTS; hops++) {
    await assertPublicUrl(current);
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    let res: Response;
    try {
      res = await fetch(current.toString(), {
        redirect: "manual",
        signal: ctl.signal,
        headers: {
          "User-Agent": "secpulse-portal-scraper/1.0 (+https://github.com/Nebta/Security-Pulse-Agent)",
          Accept: acceptedTypes.join(", "),
        },
      });
    } finally {
      clearTimeout(t);
    }
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      if (!loc) throw new Error(`Redirect without Location header at ${current}`);
      current = new URL(loc, current);
      continue;
    }
    if (!res.ok) {
      throw new Error(`Upstream returned ${res.status} for ${current}`);
    }
    const contentType = (res.headers.get("content-type") ?? "").toLowerCase();
    if (!acceptedTypes.some(t => contentType.includes(t.split(";")[0].trim()))) {
      throw new Error(`Unexpected content-type ${contentType || "(none)"} (want one of ${acceptedTypes.join(", ")})`);
    }
    const reader = res.body?.getReader();
    if (!reader) throw new Error("Upstream returned no body");
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        total += value.length;
        if (total > MAX_BYTES) { try { await reader.cancel(); } catch {}; throw new Error(`Response exceeded ${MAX_BYTES} byte cap`); }
        chunks.push(value);
      }
    }
    return { bodyBuf: Buffer.concat(chunks.map(c => Buffer.from(c))), contentType, finalUrl: current };
  }
  throw new Error(`Too many redirects (>${MAX_REDIRECTS})`);
}

function findMeta(html: string, patterns: RegExp[]): string | null {
  for (const re of patterns) {
    const m = html.match(re);
    if (m && m[1]) return m[1].trim();
  }
  return null;
}

function deriveCustomerId(hostname: string): string | null {
  // example.co.uk -> EXAMPLE. Strip common TLDs then non-alnum.
  const parts = hostname.toLowerCase().split(".").filter(Boolean);
  if (parts.length === 0) return null;
  // If the second-to-last is a well-known second-level public suffix, use third-to-last.
  const secondLevel = new Set(["co", "com", "net", "org", "gov", "ac", "edu"]);
  let host: string;
  if (parts.length >= 3 && secondLevel.has(parts[parts.length - 2])) host = parts[parts.length - 3];
  else if (parts.length >= 2) host = parts[parts.length - 2];
  else host = parts[0];
  const cleaned = host.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (cleaned.length < 2) return null;
  return cleaned.slice(0, 20);
}

export async function scrapeUrl(rawUrl: string): Promise<ScrapeResult> {
  let url: URL;
  try { url = new URL(rawUrl); } catch { throw new Error("Invalid URL"); }

  const { bodyBuf, finalUrl } = await fetchWithLimits(url, ["text/html", "application/xhtml+xml"]);
  const html = bodyBuf.toString("utf-8");

  const title = findMeta(html, [
    /<meta[^>]+property=["']og:site_name["'][^>]+content=["']([^"']+)["']/i,
    /<meta[^>]+name=["']application-name["'][^>]+content=["']([^"']+)["']/i,
    /<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i,
    /<title[^>]*>([^<]+)<\/title>/i,
  ]);
  const imageUrl = findMeta(html, [
    /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i,
  ]);
  const primaryColor = findMeta(html, [
    /<meta[^>]+name=["']theme-color["'][^>]+content=["']([^"']+)["']/i,
    /<meta[^>]+name=["']msapplication-TileColor["'][^>]+content=["']([^"']+)["']/i,
  ]);
  const faviconHref = findMeta(html, [
    /<link[^>]+rel=["'](?:shortcut icon|icon|apple-touch-icon)["'][^>]+href=["']([^"']+)["']/i,
    /<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:shortcut icon|icon|apple-touch-icon)["']/i,
  ]);

  // Best-effort: resolve + inline favicon as data URL so the SPA can
  // render it without us having to widen the CSP to external image
  // hosts.
  let faviconDataUrl: string | null = null;
  const faviconCandidate = faviconHref ? new URL(faviconHref, finalUrl) : new URL("/favicon.ico", finalUrl);
  try {
    const { bodyBuf: favBuf, contentType: favType } = await fetchWithLimits(faviconCandidate, ["image/"]);
    const cleanType = favType.split(";")[0].trim() || "image/x-icon";
    // Cap data-URL at 64 KB — browsers handle larger but the SPA only needs a 32x32 icon.
    if (favBuf.length <= 64 * 1024) {
      faviconDataUrl = `data:${cleanType};base64,${favBuf.toString("base64")}`;
    }
  } catch { /* favicon is best-effort */ }

  const displayName = title ? title.replace(/\s+[|•–-].*$/, "").trim() || title.trim() : null;
  const suggestedCustomerId = deriveCustomerId(finalUrl.hostname);

  return {
    title,
    displayName,
    suggestedCustomerId,
    primaryColor,
    faviconDataUrl,
    imageUrl: imageUrl ? new URL(imageUrl, finalUrl).toString() : null,
    finalUrl: finalUrl.toString(),
  };
}
