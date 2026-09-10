# invoice.finecut.com

> **Not deployed.** This was stood up once and taken down again — the Worker
> and its KV namespace are deleted, and nothing was ever published through it.
> The code and its tests are kept here in case the idea comes back; deploying
> it is the four commands below and nothing else in the app changes, because
> publishing stays off until an address and token are set in Settings.

A Cloudflare Worker that serves invoices the Mac app has published. Nothing is
uploaded until you press **Share** on an invoice; unpublishing deletes it.

## What it holds

Workers KV, one entry per published invoice: the PDF bytes, plus a small
metadata block for the page around it — number, dates, amount due, status,
business name, accent colour, filename. **Payment details are not in the
metadata.** They stay inside the PDF, exactly as they are when you email it.

## Deploy

You need the Cloudflare account that owns finecut.com. Four commands:

```bash
cd web
npx wrangler login
npx wrangler kv namespace create INVOICES     # paste the id into wrangler.toml
npx wrangler secret put PUBLISH_TOKEN         # paste a long random token
npx wrangler deploy                           # creates invoice.finecut.com
```

Generate the token with `openssl rand -base64 32`. Keep a copy — you paste the
same value into the app under Settings ▸ Publishing.

## Then, in the app

Settings ▸ Publishing: address `https://invoice.finecut.com`, and the token.
The token is stored in the login Keychain, never in `data.json`.

## Routes

| Route | Method | Auth | Purpose |
| --- | --- | --- | --- |
| `/i/<id>` | GET | none | The client-facing page |
| `/i/<id>.pdf` | GET | none | The PDF itself |
| `/publish/<id>` | PUT | bearer | Publish or update |
| `/publish/<id>` | DELETE | bearer | Unpublish |

Every response is `noindex`, and an unknown id is a plain 404 that doesn't say
whether an invoice was ever there.

## The security shape, stated plainly

A published link is a **capability**: the id is 12 random hex characters, and
anyone holding the URL can open that one invoice. That is what makes it usable
for a client — no account, no password, works on a phone. It is not
password-protected, so treat the link like the invoice. Unpublish when a job is
done.

If you ever want links to require a login, put Cloudflare Access in front of
`/i/*` — the Worker doesn't need to change.

## Tests

```bash
npm test
```

Runs the Worker against a mock KV: auth (missing, wrong-but-same-length, right),
publish, view, PDF round-trip, HTML escaping of metadata, accent-colour
validation, 404s for unknown ids and the root, and that unpublish kills the link.
