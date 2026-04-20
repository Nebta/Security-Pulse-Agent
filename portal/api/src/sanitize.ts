/**
 * Conservative HTML template sanitizer for customer email templates.
 *
 * Returns either the input HTML unchanged (if safe) or an array of
 * human-readable validation errors. We intentionally reject — not strip —
 * dangerous content so the operator sees exactly what was wrong.
 *
 * Rules:
 *   - Max size 256 KB.
 *   - Must contain the required workflow placeholders.
 *   - Reject <script>, <iframe>, <object>, <embed>, <form>, <link>, <meta http-equiv>, <base>, <svg ... script>.
 *   - Reject inline event handlers (on*=).
 *   - Reject javascript:/vbscript:/data: URLs in href / src / action.
 *   - Reject CSS expression() and url(javascript:...).
 */

export const REQUIRED_PLACEHOLDERS = [
  "{{SECTIONS_BLOCK}}",
  "{{EXECUTIVE_SUMMARY}}",
  "{{FOOTER_TEXT}}",
];

export const MAX_TEMPLATE_BYTES = 256 * 1024;

const FORBIDDEN_TAGS = [
  "script", "iframe", "object", "embed", "form", "link", "base",
  "frame", "frameset", "applet",
];

export function sanitizeTemplate(html: string): { ok: true } | { ok: false; errors: string[] } {
  const errors: string[] = [];

  if (typeof html !== "string") {
    return { ok: false, errors: ["template body must be a string"] };
  }
  const bytes = Buffer.byteLength(html, "utf-8");
  if (bytes > MAX_TEMPLATE_BYTES) {
    errors.push(`template too large (${bytes} bytes; max ${MAX_TEMPLATE_BYTES})`);
  }

  for (const placeholder of REQUIRED_PLACEHOLDERS) {
    if (!html.includes(placeholder)) {
      errors.push(`missing required placeholder ${placeholder}`);
    }
  }

  for (const tag of FORBIDDEN_TAGS) {
    if (new RegExp(`<\\s*${tag}\\b`, "i").test(html)) {
      errors.push(`forbidden tag <${tag}>`);
    }
  }

  if (/<\s*meta\b[^>]*\bhttp-equiv\b/i.test(html)) {
    errors.push("forbidden tag <meta http-equiv>");
  }

  if (/\son[a-z]+\s*=/i.test(html)) {
    errors.push("forbidden inline event handler attribute (on*=)");
  }

  if (/(?:href|src|action|formaction|background|xlink:href)\s*=\s*['"]?\s*(?:javascript|vbscript|data)\s*:/i.test(html)) {
    errors.push("forbidden javascript:/vbscript:/data: URL in href/src/action");
  }

  if (/expression\s*\(/i.test(html)) {
    errors.push("forbidden CSS expression()");
  }
  if (/url\s*\(\s*['"]?\s*(?:javascript|vbscript)\s*:/i.test(html)) {
    errors.push("forbidden javascript:/vbscript: URL in CSS url()");
  }

  if (errors.length) return { ok: false, errors };
  return { ok: true };
}
