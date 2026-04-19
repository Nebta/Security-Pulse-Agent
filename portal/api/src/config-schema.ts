/**
 * Validates a customer config.json payload before writing back to blob.
 * Mirrors the schema the Logic App's Parse_Customer_Config expects (keep
 * in sync with infra/modules/workflow.json). Returns either the cleaned
 * object or an array of human-readable validation messages.
 */
export interface CustomerConfig {
  customerId: string;
  displayName: string;
  logoUrl?: string;
  primaryColor?: string;
  accentColor?: string;
  headerTextColor?: string;
  footerText?: string;
  audience?: string;
  industry?: string;
  tone?: string;
  focusAreas?: string[];
  sectionsEnabled?: Record<string, boolean>;
  language?: "en" | "de";
  recipients?: { default?: string[]; exec?: string[]; tech?: string[] };
  pdfAttachment?: boolean;
  pdfDriveUserUpn?: string;
  teamsWebhookUrl?: string;
  pii?: { blockSubstrings?: string[]; abortOnFinding?: boolean };
}

const KNOWN_SECTIONS = [
  "vulnerabilities", "threatLandscape", "mdtiHighlights", "xdrIncidents",
  "sentinelIncidents", "riskyIdentities", "entraIdProtection",
  "intuneCompliance", "purviewDlp", "sentinelCost",
];

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

function isStringArray(v: unknown): v is string[] {
  return Array.isArray(v) && v.every(x => typeof x === "string");
}

export function validateConfig(input: unknown, expectedCustomerId: string): { ok: true; value: CustomerConfig } | { ok: false; errors: string[] } {
  const errors: string[] = [];
  if (typeof input !== "object" || !input) {
    return { ok: false, errors: ["body must be a JSON object"] };
  }
  const o = input as Record<string, unknown>;

  if (typeof o.customerId !== "string" || o.customerId !== expectedCustomerId) {
    errors.push(`customerId must equal "${expectedCustomerId}"`);
  }
  if (typeof o.displayName !== "string" || !o.displayName.trim()) {
    errors.push("displayName is required");
  }
  for (const k of ["primaryColor", "accentColor", "headerTextColor"]) {
    if (o[k] !== undefined && o[k] !== "" && (typeof o[k] !== "string" || !HEX_COLOR.test(o[k] as string))) {
      errors.push(`${k} must be a #RRGGBB hex colour`);
    }
  }
  if (o.focusAreas !== undefined && !isStringArray(o.focusAreas)) {
    errors.push("focusAreas must be string[]");
  }
  if (o.language !== undefined && o.language !== "en" && o.language !== "de") {
    errors.push("language must be 'en' or 'de'");
  }
  if (o.sectionsEnabled !== undefined) {
    if (typeof o.sectionsEnabled !== "object" || o.sectionsEnabled === null) {
      errors.push("sectionsEnabled must be an object");
    } else {
      for (const [k, v] of Object.entries(o.sectionsEnabled)) {
        if (typeof v !== "boolean") errors.push(`sectionsEnabled.${k} must be boolean`);
        if (!KNOWN_SECTIONS.includes(k)) errors.push(`unknown section: ${k}`);
      }
    }
  }
  if (o.recipients !== undefined) {
    const r = o.recipients as Record<string, unknown>;
    for (const k of ["default", "exec", "tech"]) {
      if (r[k] !== undefined && !isStringArray(r[k])) errors.push(`recipients.${k} must be string[]`);
    }
  }
  if (o.pdfAttachment !== undefined && typeof o.pdfAttachment !== "boolean") {
    errors.push("pdfAttachment must be boolean");
  }
  if (o.teamsWebhookUrl !== undefined && o.teamsWebhookUrl !== "" && typeof o.teamsWebhookUrl !== "string") {
    errors.push("teamsWebhookUrl must be string");
  }
  if (o.pii !== undefined) {
    const p = o.pii as Record<string, unknown>;
    if (p.blockSubstrings !== undefined && !isStringArray(p.blockSubstrings)) {
      errors.push("pii.blockSubstrings must be string[]");
    }
    if (p.abortOnFinding !== undefined && typeof p.abortOnFinding !== "boolean") {
      errors.push("pii.abortOnFinding must be boolean");
    }
  }

  if (errors.length) return { ok: false, errors };
  return { ok: true, value: o as unknown as CustomerConfig };
}
