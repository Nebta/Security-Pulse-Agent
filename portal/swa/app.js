// Security Pulse Portal — vanilla ES module, no build step.
// Renders into #root. Talks to /api/* (linked Function App) and uses SWA's
// built-in Entra auth via /.auth/me + /.auth/login/aad.

const KNOWN_SECTIONS = [
  "vulnerabilities", "threatLandscape", "mdtiHighlights", "xdrIncidents",
  "sentinelIncidents", "riskyIdentities", "entraIdProtection",
  "intuneCompliance", "purviewDlp", "sentinelCost",
];

const root = document.getElementById("root");
const toastEl = document.getElementById("toast");

function toast(msg, isErr = false) {
  toastEl.textContent = msg;
  toastEl.className = "toast" + (isErr ? " err" : "");
  toastEl.style.display = "block";
  setTimeout(() => { toastEl.style.display = "none"; }, 3500);
}

function el(tag, attrs = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v;
    else if (k.startsWith("on") && typeof v === "function") e.addEventListener(k.slice(2).toLowerCase(), v);
    else if (v === true) e.setAttribute(k, "");
    else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    e.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return e;
}

async function api(path, init = {}) {
  const res = await fetch("/api" + path, {
    ...init,
    headers: { "Content-Type": "application/json", ...(init.headers || {}) },
  });
  if (!res.ok) {
    let msg = `${res.status} ${res.statusText}`;
    try { const j = await res.json(); msg = j.error || msg; if (j.details) msg += " — " + j.details.join("; "); } catch {}
    throw new Error(msg);
  }
  return res.status === 204 ? null : res.json();
}

function fmtTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return d.toLocaleString();
}
function fmtDuration(start, end) {
  if (!start || !end) return "—";
  const ms = new Date(end) - new Date(start);
  if (ms < 1000) return ms + "ms";
  if (ms < 60_000) return (ms / 1000).toFixed(1) + "s";
  return Math.floor(ms / 60_000) + "m " + Math.floor((ms % 60_000) / 1000) + "s";
}

// -------- screens --------

function renderLogin(message) {
  root.replaceChildren(
    el("main", {},
      el("div", { class: "card login" },
        el("h1", {}, "Security Pulse Portal"),
        el("p", {}, message ?? "Sign in with your Entra account to continue."),
        el("p", {},
          el("a", { href: "/.auth/login/aad?post_login_redirect_uri=/" },
            el("button", {}, "Sign in"))
        ),
      )
    )
  );
}

function renderHeader(me, current, customers, onSwitch) {
  return el("header", {},
    el("div", {},
      el("h1", {}, "Security Pulse Portal"),
    ),
    el("div", {},
      customers.length > 1 && el("select", { id: "cust-switch", onchange: e => onSwitch(e.target.value) },
        ...customers.map(c => el("option", { value: c, selected: c === current ? true : false }, c))
      ),
      el("span", { class: "who" }, " ", me.user, " "),
      el("a", { href: "/.auth/logout?post_logout_redirect_uri=/" }, "Sign out"),
    ),
  );
}

function buildConfigForm(cfg) {
  // Inputs are populated from cfg; on save we read them back and merge into cfg.
  const sections = cfg.sectionsEnabled || {};
  const recipients = cfg.recipients || {};
  const pii = cfg.pii || { blockSubstrings: [], abortOnFinding: false };

  const sectionInputs = KNOWN_SECTIONS.map(s =>
    el("label", { style: "display:flex;align-items:center;gap:6px;font-weight:400;font-size:13px;color:var(--fg);margin-bottom:0;" },
      el("input", { type: "checkbox", "data-section": s, checked: sections[s] !== false ? true : false }),
      s
    )
  );

  const form = el("form", { id: "cfg-form", onsubmit: e => e.preventDefault() },
    el("div", { class: "grid2" },
      el("div", {}, el("label", {}, "Display name"),
        el("input", { type: "text", id: "cfg-displayName", value: cfg.displayName || "" })),
      el("div", {}, el("label", {}, "Language"),
        el("select", { id: "cfg-language" },
          el("option", { value: "en", selected: (cfg.language ?? "en") === "en" ? true : false }, "English"),
          el("option", { value: "de", selected: cfg.language === "de" ? true : false }, "German"),
        )),
    ),
    el("div", { class: "grid3", style: "margin-top:12px;" },
      el("div", {}, el("label", {}, "Primary colour"),
        el("input", { type: "text", id: "cfg-primaryColor", value: cfg.primaryColor || "" })),
      el("div", {}, el("label", {}, "Accent colour"),
        el("input", { type: "text", id: "cfg-accentColor", value: cfg.accentColor || "" })),
      el("div", {}, el("label", {}, "Header text colour"),
        el("input", { type: "text", id: "cfg-headerTextColor", value: cfg.headerTextColor || "" })),
    ),
    el("div", { style: "margin-top:16px;" },
      el("label", {}, "Sections enabled"),
      el("div", { class: "grid-sec" }, ...sectionInputs),
    ),
    el("div", { class: "grid3", style: "margin-top:16px;" },
      el("div", {}, el("label", {}, "Recipients (default) — one per line"),
        el("textarea", { id: "cfg-recipients-default" }, (recipients.default || []).join("\n"))),
      el("div", {}, el("label", {}, "Recipients (exec)"),
        el("textarea", { id: "cfg-recipients-exec" }, (recipients.exec || []).join("\n"))),
      el("div", {}, el("label", {}, "Recipients (tech)"),
        el("textarea", { id: "cfg-recipients-tech" }, (recipients.tech || []).join("\n"))),
    ),
    el("div", { class: "grid3", style: "margin-top:16px;" },
      el("div", {},
        el("label", { style: "display:flex;align-items:center;gap:6px;font-weight:400;color:var(--fg);" },
          el("input", { type: "checkbox", id: "cfg-pdfAttachment", checked: cfg.pdfAttachment ? true : false }),
          "Attach PDF"),
        el("label", { style: "display:flex;align-items:center;gap:6px;font-weight:400;color:var(--fg);margin-top:4px;" },
          el("input", { type: "checkbox", id: "cfg-pii-abort", checked: pii.abortOnFinding ? true : false }),
          "PII guard: abort on finding"),
      ),
      el("div", {}, el("label", {}, "Teams webhook URL"),
        el("input", { type: "text", id: "cfg-teamsWebhookUrl", value: cfg.teamsWebhookUrl || "" })),
      el("div", {}, el("label", {}, "PII block substrings — one per line"),
        el("textarea", { id: "cfg-pii-blocks" }, (pii.blockSubstrings || []).join("\n"))),
    ),
    el("div", { class: "row", style: "margin-top:18px;justify-content:flex-end;" },
      el("button", { id: "cfg-save", type: "button" }, "Save config"),
    ),
  );
  return form;
}

function readFormToConfig(prev) {
  const lines = id => document.getElementById(id).value.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  const next = { ...prev };
  next.displayName = document.getElementById("cfg-displayName").value.trim();
  next.language = document.getElementById("cfg-language").value;
  for (const k of ["primaryColor", "accentColor", "headerTextColor"]) {
    const v = document.getElementById("cfg-" + k).value.trim();
    if (v) next[k] = v; else delete next[k];
  }
  const sections = { ...(prev.sectionsEnabled || {}) };
  for (const cb of document.querySelectorAll("[data-section]")) {
    sections[cb.dataset.section] = cb.checked;
  }
  next.sectionsEnabled = sections;
  next.recipients = {
    default: lines("cfg-recipients-default"),
    exec:    lines("cfg-recipients-exec"),
    tech:    lines("cfg-recipients-tech"),
  };
  next.pdfAttachment = document.getElementById("cfg-pdfAttachment").checked;
  const teams = document.getElementById("cfg-teamsWebhookUrl").value.trim();
  if (teams) next.teamsWebhookUrl = teams; else delete next.teamsWebhookUrl;
  next.pii = {
    blockSubstrings: lines("cfg-pii-blocks"),
    abortOnFinding:  document.getElementById("cfg-pii-abort").checked,
  };
  return next;
}

function renderRunsTable(runs) {
  if (!runs.length) return el("p", { class: "muted" }, "No runs yet.");
  return el("table", {},
    el("thead", {}, el("tr", {},
      el("th", {}, "Started"), el("th", {}, "Duration"),
      el("th", {}, "Status"), el("th", {}, "Run id"), el("th", {}, "Error"))),
    el("tbody", {}, ...runs.map(r =>
      el("tr", {},
        el("td", {}, fmtTime(r.startTime)),
        el("td", {}, fmtDuration(r.startTime, r.endTime)),
        el("td", {}, el("span", { class: "status-" + r.status }, r.status)),
        el("td", {}, el("code", {}, r.id)),
        el("td", {}, r.errorMessage ? el("span", { title: r.errorMessage }, (r.errorMessage || "").slice(0, 80)) : "—"),
      ))),
  );
}

async function loadCustomer(me, id) {
  root.replaceChildren(
    renderHeader(me, id, me.customers, async (newId) => {
      history.replaceState({}, "", "?c=" + encodeURIComponent(newId));
      await loadCustomer(me, newId);
    }),
    el("main", {}, el("p", {}, "Loading ", id, "…"))
  );

  let cfg, runsData;
  try {
    [cfg, runsData] = await Promise.all([
      api(`/customers/${id}/config`),
      api(`/customers/${id}/runs?top=20`),
    ]);
  } catch (e) {
    root.replaceChildren(
      renderHeader(me, id, me.customers, async (newId) => loadCustomer(me, newId)),
      el("main", {}, el("div", { class: "card" }, el("div", { class: "err-box" }, "Failed to load: " + e.message)))
    );
    return;
  }

  const triggerBtn = el("button", { id: "trigger-btn" }, "Run now");
  triggerBtn.addEventListener("click", async () => {
    triggerBtn.disabled = true;
    try {
      await api(`/customers/${id}/trigger`, { method: "POST" });
      toast("Triggered. The new run will appear in the list within a minute.");
      setTimeout(async () => {
        try {
          const data = await api(`/customers/${id}/runs?top=20`);
          document.getElementById("runs-area").replaceChildren(renderRunsTable(data.runs));
        } catch {}
        triggerBtn.disabled = false;
      }, 8000);
    } catch (e) { toast("Trigger failed: " + e.message, true); triggerBtn.disabled = false; }
  });

  const form = buildConfigForm(cfg);

  root.replaceChildren(
    renderHeader(me, id, me.customers, async (newId) => {
      history.replaceState({}, "", "?c=" + encodeURIComponent(newId));
      await loadCustomer(me, newId);
    }),
    el("main", {},
      el("div", { class: "card" },
        el("h2", { style: "margin-top:0;" }, "Configuration — ", cfg.displayName || id),
        form,
      ),
      el("div", { class: "card" },
        el("div", { class: "row", style: "justify-content:space-between;" },
          el("h2", { style: "margin:0;" }, "Recent runs"),
          triggerBtn,
        ),
        el("div", { id: "runs-area", style: "margin-top:12px;" }, renderRunsTable(runsData.runs)),
      ),
    ),
  );

  document.getElementById("cfg-save").addEventListener("click", async () => {
    const btn = document.getElementById("cfg-save");
    btn.disabled = true;
    try {
      const next = readFormToConfig(cfg);
      await api(`/customers/${id}/config`, { method: "PUT", body: JSON.stringify(next) });
      cfg = next;
      toast("Saved. The next run picks it up.");
    } catch (e) { toast("Save failed: " + e.message, true); }
    finally { btn.disabled = false; }
  });
}

async function boot() {
  // SWA's /.auth/me is unauthenticated and tells us if there's an active principal.
  let auth;
  try { auth = await (await fetch("/.auth/me")).json(); }
  catch { renderLogin("Authentication endpoint unavailable."); return; }
  const principal = auth?.clientPrincipal;
  if (!principal) { renderLogin(); return; }

  // /api/me also enforces our PORTAL_ALLOWED_UPNS allowlist.
  let me;
  try { me = await api("/me"); }
  catch (e) { renderLogin("Signed in as " + principal.userDetails + " but " + e.message + ". Ask the operator to add your UPN to PORTAL_ALLOWED_UPNS."); return; }

  if (!me.customers?.length) {
    root.replaceChildren(el("main", {}, el("div", { class: "card" },
      el("h2", {}, "No customers configured"),
      el("p", {}, "PORTAL_CUSTOMERS is empty. Add at least one customer in the Function App settings.")
    )));
    return;
  }
  const requested = new URL(location.href).searchParams.get("c");
  const id = me.customers.includes(requested) ? requested : me.customers[0];
  await loadCustomer(me, id);
}

boot().catch(e => {
  console.error(e);
  root.replaceChildren(el("main", {}, el("div", { class: "card" },
    el("div", { class: "err-box" }, "Portal failed to start: " + e.message))));
});
