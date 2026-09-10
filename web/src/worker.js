/**
 * invoice.finecut.com — serves invoices you have explicitly published.
 *
 * Design notes:
 *
 * - A link is a capability: the id is unguessable and anyone holding the URL
 *   can view that one invoice. That is what a client needs — no account, no
 *   password, works from any device. It is *not* a secret store, so the page
 *   shows the invoice's shape (number, dates, total, status) and nothing else;
 *   bank and Zelle details stay inside the PDF where they already were.
 * - Publishing and unpublishing require a bearer token held by the Mac app.
 * - Everything is marked noindex, and unknown ids answer 404 without hinting
 *   whether an invoice ever existed there.
 */

const HTML_HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "x-robots-tag": "noindex, nofollow",
  "referrer-policy": "no-referrer",
  "content-security-policy":
    "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; object-src 'self'; frame-src 'self'",
};

function notFound() {
  return new Response("Not found", { status: 404, headers: { "x-robots-tag": "noindex" } });
}

function authorised(request, env) {
  const header = request.headers.get("authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  // Constant-time-ish: compare lengths first, then every byte.
  if (!env.PUBLISH_TOKEN || token.length !== env.PUBLISH_TOKEN.length) return false;
  let difference = 0;
  for (let i = 0; i < token.length; i++) {
    difference |= token.charCodeAt(i) ^ env.PUBLISH_TOKEN.charCodeAt(i);
  }
  return difference === 0;
}

function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

function page(meta, id) {
  const accent = /^#[0-9a-fA-F]{6}$/.test(meta.accent || "") ? meta.accent : "#7C7C7C";
  const status = escapeHTML(meta.status || "");
  const rows = [
    ["Invoice", meta.number],
    ["Issued", meta.issueDate],
    ["Due", meta.dueDate],
  ]
    .filter(([, value]) => value)
    .map(([label, value]) =>
      `<div class="row"><dt>${escapeHTML(label)}</dt><dd>${escapeHTML(value)}</dd></div>`)
    .join("");

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Invoice ${escapeHTML(meta.number || "")} — ${escapeHTML(meta.business || "")}</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
         background: #f6f6f5; color: #1b1a19; }
  @media (prefers-color-scheme: dark) { body { background: #17181a; color: #ececec; } .card { background: #1f2022; } }
  .banner { background: ${accent}; color: #fff; padding: 28px 20px; }
  .banner h1 { margin: 0; font-size: 26px; font-weight: 500; letter-spacing: .04em; }
  .banner p { margin: 4px 0 0; opacity: .9; font-size: 14px; }
  main { max-width: 820px; margin: 0 auto; padding: 20px; }
  .card { background: #fff; border-radius: 10px; padding: 18px 20px; margin-bottom: 16px;
          box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .amount { font-size: 30px; font-weight: 600; margin: 0 0 2px; font-variant-numeric: tabular-nums; }
  .muted { color: #6b6a68; font-size: 13px; }
  .row { display: flex; justify-content: space-between; padding: 7px 0; border-bottom: 1px solid rgba(128,128,128,.18); }
  .row:last-child { border-bottom: 0; }
  dt, dd { margin: 0; } dt { color: #6b6a68; } dd { font-variant-numeric: tabular-nums; }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 4px; }
  a.button { display: inline-block; background: ${accent}; color: #fff; text-decoration: none;
             padding: 11px 18px; border-radius: 8px; font-weight: 600; }
  object { width: 100%; height: 78vh; border: 0; border-radius: 10px; background: #fff; }
  footer { text-align: center; padding: 22px; }
</style>
</head><body>
  <div class="banner">
    <h1>${escapeHTML(meta.title || "INVOICE")}</h1>
    <p>${escapeHTML(meta.business || "")}</p>
  </div>
  <main>
    <div class="card">
      <p class="amount">${escapeHTML(meta.amountDue || "")}</p>
      <p class="muted">Amount due${status ? ` · ${status}` : ""}</p>
      <dl>${rows}</dl>
      <div class="actions">
        <a class="button" href="/i/${encodeURIComponent(id)}.pdf" download>Download PDF</a>
      </div>
    </div>
    <div class="card">
      <object data="/i/${encodeURIComponent(id)}.pdf" type="application/pdf">
        <p class="muted">Your browser can't show the PDF inline — use the download button above.</p>
      </object>
    </div>
    <footer class="muted">Payment details are on the invoice itself.</footer>
  </main>
</body></html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const publish = url.pathname.match(/^\/publish\/([A-Za-z0-9_-]{8,64})$/);

    if (publish) {
      if (!authorised(request, env)) return new Response("Unauthorized", { status: 401 });
      const id = publish[1];

      if (request.method === "PUT") {
        const meta = JSON.parse(request.headers.get("x-invoice-meta") || "{}");
        const body = await request.arrayBuffer();
        if (body.byteLength === 0) return new Response("Empty body", { status: 400 });
        if (body.byteLength > 20 * 1024 * 1024) return new Response("Too large", { status: 413 });
        await env.INVOICES.put(id, body, { metadata: meta });
        return Response.json({ ok: true, url: `${url.origin}/i/${id}` });
      }

      if (request.method === "DELETE") {
        await env.INVOICES.delete(id);
        return Response.json({ ok: true });
      }

      return new Response("Method not allowed", { status: 405 });
    }

    const view = url.pathname.match(/^\/i\/([A-Za-z0-9_-]{8,64})(\.pdf)?$/);
    if (view && request.method === "GET") {
      const [, id, wantsPDF] = view;
      const { value, metadata } = await env.INVOICES.getWithMetadata(id, { type: "arrayBuffer" });
      if (!value) return notFound();

      if (wantsPDF) {
        return new Response(value, {
          headers: {
            "content-type": "application/pdf",
            "content-disposition": `inline; filename="${(metadata?.fileName || "invoice.pdf").replace(/[^\w.\-]/g, "_")}"`,
            "x-robots-tag": "noindex",
            "cache-control": "private, max-age=60",
          },
        });
      }
      return new Response(page(metadata || {}, id), { headers: HTML_HEADERS });
    }

    return notFound();
  },
};
