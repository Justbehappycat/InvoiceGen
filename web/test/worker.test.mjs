import worker from "../src/worker.js";

// A stand-in for Workers KV: enough of the surface for these tests.
const store = new Map();
const env = {
  PUBLISH_TOKEN: "test-token-abcdefghijklmnop",
  INVOICES: {
    async put(key, value, options) { store.set(key, { value, metadata: options?.metadata }); },
    async delete(key) { store.delete(key); },
    async getWithMetadata(key) { return store.get(key) ?? { value: null, metadata: null }; },
  },
};

let failures = 0;
function check(label, condition, detail = "") {
  if (condition) { console.log(`  ok    ${label}`); }
  else { failures++; console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ""}`); }
}

const id = "8fa3c19d2b7e";
const pdf = new TextEncoder().encode("%PDF-1.7 pretend").buffer;
const meta = {
  number: "17", business: "Finecut Studio LLC", title: "INVOICE",
  amountDue: "$400.00", issueDate: "September 10, 2026", dueDate: "October 10, 2026",
  status: "Sent", accent: "#7C7C7C", fileName: "Invoice_17.pdf",
};
const put = (headers, body = pdf, method = "PUT") =>
  worker.fetch(new Request(`https://invoice.finecut.com/publish/${id}`, { method, headers, body }), env);

console.log("publishing");
let res = await put({ "x-invoice-meta": JSON.stringify(meta) });
check("rejects a missing token", res.status === 401, `got ${res.status}`);

res = await put({ authorization: "Bearer wrong-token-aaaaaaaaaaaa", "x-invoice-meta": "{}" });
check("rejects a wrong token of equal length", res.status === 401, `got ${res.status}`);

res = await put({ authorization: `Bearer ${env.PUBLISH_TOKEN}`, "x-invoice-meta": JSON.stringify(meta) });
const published = await res.json();
check("accepts the real token", res.status === 200 && published.ok === true);
check("returns the public link", published.url === `https://invoice.finecut.com/i/${id}`, published.url);

res = await put({ authorization: `Bearer ${env.PUBLISH_TOKEN}` }, new ArrayBuffer(0));
check("refuses an empty body", res.status === 400, `got ${res.status}`);

console.log("viewing");
res = await worker.fetch(new Request(`https://invoice.finecut.com/i/${id}`), env);
const html = await res.text();
check("serves the page", res.status === 200);
check("marked noindex", res.headers.get("x-robots-tag").includes("noindex"));
check("shows the amount due", html.includes("$400.00"));
check("shows the invoice number", html.includes(">17<"));
check("links the PDF", html.includes(`/i/${id}.pdf`));

res = await worker.fetch(new Request(`https://invoice.finecut.com/i/${id}.pdf`), env);
check("serves the PDF", res.status === 200 && res.headers.get("content-type") === "application/pdf");
check("PDF bytes come back intact",
      new TextDecoder().decode(await res.arrayBuffer()) === "%PDF-1.7 pretend");

console.log("safety");
store.set("evilid00", {
  value: pdf,
  metadata: { ...meta, business: '<script>alert(1)</script>', accent: "javascript:alert(1)" },
});
const evil = await (await worker.fetch(new Request("https://invoice.finecut.com/i/evilid00"), env)).text();
check("escapes metadata into the page", !evil.includes("<script>alert(1)</script>"));
check("refuses a non-hex accent", !evil.includes("javascript:alert(1)"));

res = await worker.fetch(new Request("https://invoice.finecut.com/i/doesnotexist"), env);
check("unknown id is a plain 404", res.status === 404);
res = await worker.fetch(new Request("https://invoice.finecut.com/"), env);
check("root is a 404, not a listing", res.status === 404);
res = await worker.fetch(new Request("https://invoice.finecut.com/i/../publish/x"), env);
check("path traversal gets nothing", res.status === 404);

console.log("unpublishing");
res = await put({ authorization: `Bearer ${env.PUBLISH_TOKEN}` }, undefined, "DELETE");
check("delete succeeds", res.status === 200);
res = await worker.fetch(new Request(`https://invoice.finecut.com/i/${id}`), env);
check("the link is dead afterwards", res.status === 404);

console.log(failures === 0 ? "\nall worker checks passed" : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
