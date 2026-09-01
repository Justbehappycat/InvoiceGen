# InvoiceGen

A standalone, fully offline macOS app for making invoices in the same layout as the
Wave invoice this was modelled on. No account, no network, no subscription — all data
lives in a single JSON file on your Mac.

## Build & install

```bash
./build.sh
cp -R build/InvoiceGen.app /Applications/
```

Requires Xcode command line tools (Swift 5.9+). macOS 13 or newer.

## What it does

**Invoices**
- Banner template matching the sample invoice (accent color configurable) plus a Minimal template.
- Line items with description, quantity, price, per-line taxable flag.
- Discount (flat or %), tax at any rate, partial payments, amount due.
- Status: Draft / Sent / Paid, with automatic overdue flagging. Change it from
  the sidebar's right-click menu; "Mark as Paid" also settles the amount (⌘Z
  puts both back).
- The sidebar leads with what still needs doing: overdue first, then unpaid by
  soonest due date, then paid — visible and searchable, just sunk to the bottom.
- "Today" beside the invoice date moves it to today and drags the due date with
  it, so a 30-day invoice stays a 30-day invoice.
- Duplicate any invoice, save one as a named template, or apply a template to the
  invoice you're editing (Reuse menu).
- Templates carry items, terms, tax, notes and payment details — not the customer
  or the dates. Start one from the sidebar's New menu; manage them in the Library.
- Undo/redo (⌘Z / ⇧⌘Z) across every edit, with edits made in a burst collapsed
  into a single step.
- Live page preview beside the editor, paginated exactly like the exported PDF.
  Toggle with ⇧⌘P; the choice sticks across invoices and relaunches, and hiding
  it skips the preview's layout work entirely.
- Line item columns are yours: rename them (Items / Products / Services,
  Quantity / Hours / Days, Price / Rate, Amount) and keep any of quantity,
  price, amount or the per-item description off the printed page — useful for
  flat-fee work where "1 × $2,500" says nothing. Set business-wide defaults in
  Settings, override per invoice from the Columns button above the items. The
  item column itself always prints, hidden columns stay editable, and totals
  always use quantity × price.
- Export PDF (⌘E) or Print (⌘P). Files are named `Invoice_<number>_<due date>.pdf`.
- Long invoices paginate onto real US Letter sheets — line items are never split
  across a page break, continuation pages repeat the column headers, and pages
  are filled with rows before the totals block moves to a sheet of its own.

**Invoice verification**
- **Stripes across the banner** (default): the code runs the banner's full
  height behind the title and nearly the full width of the coloured block, so a
  reading taken above or below the word crosses every column. The stripes print as a tint of the banner — a slider sets how
  dark, from 2% to 40%.
- **The app reads its own mark**, which is why the tint can be that light. A
  scanner needs 0.70 print contrast because it knows nothing about the page:
  not where the symbol is, not how big, not what it should say. The app knows
  all three, so it samples the strip at a known position, normalises against
  that strip's own range, and compares against the pattern the invoice's
  numbers should produce. Measured, at every tint from 30% down to 2%: our
  reader matches 100% of the pattern; a scanner manages only the 30% one.
- The reading can confirm but never accuse: a high match is proof the mark
  belongs to those numbers, while a low one just means the sheet carries the
  mark differently, or not at all, so it never triggers a tamper verdict on
  its own.
- The invoice title *is* the mark: solid at the caps, combing open into the
  verification code down the letterforms. Two styles, chosen in Settings:
  **inside the letters** (default) keeps the mark exactly the shape of the
  word — nothing stands in the tracking gaps, nothing extends below the
  baseline — and **with a strip** grows the same columns below the word. The cuts sit exactly on the pattern's *space* columns,
  so the ink still standing at the bottom of the letters is the bar pattern —
  the strip isn't a second object parked underneath, it's the letters
  resolving into the code. Drawn as vector paths, so it stays crisp at any
  print resolution.
- **The contained style is a brand mark, not a scannable symbol.** Code 128
  needs every column present, and the gaps between letters delete some. That
  costs nothing in practice: the code prints in the footer and the PDF check
  reads the page against it either way — `--selftest-mark` proves all three
  styles reach a verdict. The readable form (`IG1-11-0BEDBC09 · 9 items`) sits
  quietly in the footer.
- The whole mark is **one path filled from one gradient** — letters, risers and
  strip in a single body, so no part of it carries a tone of its own. That is
  what stops it reading as a word parked on top of a barcode. The foot melts
  back into the surface too, so there's no ruled bottom edge to give away where
  it was pasted on.
- Every bar column *rises* out of the strip and across the baseline, ramping
  in tone from the strip to the letters' ink. Without that the join doesn't
  stitch: the strip carries a bar in every column, but above the baseline only
  the letters carry ink, so between letters a bar appears out of nothing. With
  it, gap meets gap and bar meets bar all the way across.
- The title in the banner is set in ink rather than white for the same reason —
  a white title would force the tone ramp to cross the banner colour itself,
  which reads as mud rather than as a transition.
- The code runs through nearly the whole word (fade 0.9), leaving only the caps
  solid, so the bars blend into the letters rather than stopping partway down.
  Fade and gamma move together: raising the fade without raising gamma makes
  the cuts wide by mid-letter and the word stops reading. A linear taper eats the letters too early and the
  title stops reading; a cut wider than a stroke deletes the letter outright,
  which is why cut width is tied to the module grid rather than chosen by eye.
- The strip has two tones, and the choice is binary because print contrast
  says so. **Quiet** (a shade of the banner colour) scores PCS 0.22 against the
  0.70 floor: it looks like part of the design and does *not* scan off a
  printed page. **Ink** scores 0.85 and does. There is no tone in between that
  passes, so Settings offers the two and states plainly what each costs.
- A quiet strip does not cost you verification: the PDF check falls back to the
  code printed in the footer, and still returns a genuine/tampered verdict.
  Confirmed by `--selftest-mark`.
- Print contrast signal — `(light − dark) / light` — is the barcode standards'
  own metric, and it's what the app measures. Vision is not the arbiter: it
  will decode black bars on a near-black field that no laser scanner could
  read, and it decoded a quiet strip in a clean digital render that then failed
  off the rendered page.
- The code is an HMAC-SHA256 signature over exactly four fields: invoice
  number, invoice date, total quantity, total amount. Change any one of them
  and the code stops verifying.
- The key is derived from a passphrase you set (Settings ▸ Security ▸ Invoice
  verification, behind the same Touch ID gate as payment details) with PBKDF2
  at 200,000 rounds. The passphrase lives in the encrypted vault; the salt
  lives in `data.json`, so restoring a backup on another Mac and typing the
  same passphrase reproduces every past code.
- Verify with ⇧⌘V: scan the barcode (a handheld scanner types like a keyboard)
  or type the code. The app recomputes the signature from its own copy and
  reports genuine, mismatched, unknown, or malformed.
- **Verify a PDF on its own terms** — "Choose PDF…" reads the bars, then reads
  the invoice number, date, item count and total *off the page* and recomputes
  the signature from those. So a PDF whose printed total was edited while the
  barcode was left alone is caught, even for an invoice this Mac has never
  seen. When the invoice is held here too, the app cross-checks and reports
  drift separately: an intact sheet that no longer matches your copy means the
  invoice was edited after it was sent, which is a different problem from a
  forged sheet.
- The signed date is the invoice's *local* calendar date, matching what the
  sheet prints. Signing a UTC day would have made an evening invoice sign
  tomorrow's date and every PDF check come back a false mismatch.
- Changing the passphrase invalidates the codes on invoices already sent.

**Payment methods**
- Structured, not a notes blob: each method has a badge, a label, and label/value
  fields (Zelle ID, account number, routing number, handle, …).
- Kinds: Zelle, Bank Transfer, Wire, PayPal, Venmo, Cash App, Check, Card, Crypto, Other.
- Fields are per-kind and realistic: Zelle takes an ID (email/phone) and a name,
  PayPal an email, Venmo a handle, Cash App a cashtag — only Bank Transfer and
  Wire ask for account/routing/SWIFT. Changing a method's kind drops the old
  kind's fields instead of stacking them up (⌘Z if that was a misclick).
- Each kind defines required fields.
  They can be left blank, but they can't be deleted or relabelled — the same rule
  applies to the last line item on an invoice.
- Bank methods can take a badge for 20 common US banks (Chase, BofA, Wells Fargo,
  Citi, U.S. Bank, PNC, Capital One, TD, Truist, Schwab, Ally, Amex, Discover,
  Navy Federal, Fifth Third, Regions, Citizens, HSBC, Mercury, Chime).
- Badges are drawn from a tint + glyph — they are *not* official brand artwork.
  Drop a real logo onto any method with "Choose logo image…" if you want the
  genuine mark.
- Business-wide defaults live in Settings; every invoice keeps its own copy, so
  changing an old invoice never rewrites history. "Use defaults" re-syncs one.
- They render on the invoice in a compact two-column "HOW TO PAY" block.

**How payment details are protected**
- They are never written to `data.json`. They live in `vault.dat`, sealed with
  AES-256-GCM under a key created in your login Keychain (`WhenUnlockedThisDeviceOnly`),
  file mode 0600.
- Editing them requires authentication (Touch ID or your login password). Until
  then they are shown masked and read-only, and re-lock after 5 minutes.
- Tampering is detected, not ignored: the GCM tag catches any edit to the
  ciphertext, and a SHA-256 fingerprint kept beside the key catches a rollback to
  an older genuine vault or an outright deletion. On any failure the app refuses
  to put payment details on an invoice and says why — it never quietly prints
  someone else's account number.
- Settings ▸ Security shows the current state and an audit trail of when payment
  details changed.
- Backups exclude payment details unless you explicitly opt in (and authenticate).
- If the Keychain is unreachable — most often because the app was rebuilt or
  re-signed, since Keychain ACLs follow the signing identity — the key falls back
  to a 0600 file beside the data and Settings says so. That still encrypts the
  file at rest, but anything running as your user could read that key; a properly
  signed build keeps the key in the Keychain.

**Customers**
- Saved once and reused; each has address, contact, email, phone, internal notes.
- Per-customer history: every invoice, its status, and total billed.
- "New invoice for this customer" from the customer screen or the sidebar context menu.

**Library** (bottom of the sidebar)
- Invoice templates, and a library of reusable services/products with default prices.
- Add to any invoice from the "Add saved item" menu, or push a line item into the
  library with "Save to items library".

**Settings**
- Opens with ⌘, as a normal macOS Settings window — it is set-up, not daily work.
- Business name, address, phone, email, website, logo.
- Default payment methods.
- Accent color, template style, default currency, default payment terms.
- Default notes/terms (anything beyond payment details) and footer message — new
  invoices start from these.
- Next invoice number, data-file location, backup and restore.

## Data

Everything is stored at:

```
~/Library/Application Support/InvoiceGen/data.json
```

Saved automatically as you type. Use **File ▸ Back Up Data…** for a copy, and
**Restore From Backup…** to load one. Point the app at a different file (e.g. in
Dropbox) by setting `INVOICEGEN_DATA=/path/to/data.json` in the environment.

The sidebar carries the two day-to-day sections (Invoices, Customers). Saved
items sits in the bar at the bottom of the sidebar, and Settings is the standard
⌘, window.

Data files written by older builds are migrated on open: payment details that
lived in the notes field become structured payment methods, and the file is
rewritten in the new form. Missing keys always fall back to defaults rather than
failing the load.

On first launch the app seeds itself with the business details, logo, payment terms,
customer, and invoice #8 from the sample invoice, with the next number set to 9.
All of it is editable.

## Layout of the code

| File | Purpose |
| --- | --- |
| `Models.swift` | Invoice, Customer, LineItem, BusinessProfile, totals math |
| `Store.swift` | JSON persistence, autosave, CRUD, backup/restore |
| `ContentView.swift` | Sidebar, lists, filtering, search |
| `InvoiceEditorView.swift` | Invoice editor + live preview |
| `CustomerDetailView.swift` | Customer record and history |
| `CatalogView.swift` | Saved items library |
| `SettingsView.swift` | Business profile, branding, defaults |
| `InvoiceDocumentView.swift` | The printable sheet |
| `Paginator.swift` | Measures pages so rows don't split |
| `PDFExport.swift` | Vector PDF generation, save panel, printing |
| `SidebarView.swift` | Invoice/customer lists and section switcher |
| `InvoiceColumns.swift` | Line item column titles, visibility, shared editor |
| `VerificationMark.swift` | The title dissolving into its verification code |
| `PaymentMethod.swift` | Payment method model, kinds and badge |
| `PaymentMethodsEditor.swift` | Shared editor for defaults and per-invoice |
| `UIShot.swift` | Offscreen UI capture used to check layout |

Handy for checking output without opening the UI:

```bash
.build/debug/InvoiceGen --render-sample /tmp/out.pdf
```

And for checking layout at a given window size (writes a PNG of the real UI):

```bash
.build/debug/InvoiceGen --render-ui /tmp/ui.png 1440 900 invoices
```

The last argument is `invoices`, `customers`, `items`, `settings`, or `sidebar`.
`--selftest-mark` renders the title-mark in both strip tones and checks the
lot: the contrast of each, that ink decodes off the page and quiet doesn't,
that the footer code is readable either way, and that both still verify.
`--selftest-pdf` renders three sheets and checks the real attack: an intact PDF
verifies, a PDF whose total was edited while keeping the original barcode is
caught as tampered, an intact PDF whose invoice was edited afterwards is
flagged as differing from the record, and a PDF with no code says so.
`--selftest-verify` checks the signature end to end: that each signed field
changes the code, that a wrong passphrase is rejected, that the same passphrase
and salt reproduce a code on another Mac, and that the rendered bars scan back
to the code they encode. `--render-mock out.pdf` renders a sheet from invented
data (no real customer, business or payment details) for reviewing layout.
`--selftest-list` checks the sidebar ordering, the mark-as-paid gesture and its
undo, and the payment-term arithmetic behind the Today button.
`--selftest-columns [out.pdf]` renders the invoice with renamed and hidden
columns and checks the printed text, including that a pre-feature data file
still loads with every column visible.
`--measure-pages` prints the measured height of each candidate page, which is how
pagination problems get diagnosed. `--selftest-undo` exercises the undo stack and `--selftest-payment` the
payment-field rules.

`--profile` times the things that were actually slow: the first Keychain read,
a vault load, a save, pagination cold and warm, one rendered page, and a full
window redraw with the preview shown and hidden.

The live preview never puts `.shadow()` on the invoice itself — the shadow goes
on a plain rectangle behind it. Shadowing the live view makes AppKit rasterise
and blur the entire page on every redraw (measured: 360ms per page, so ~640ms
to redraw the window against 42ms without), which is exactly what happens when
you switch to the app and every control repaints in its active state.

The first Keychain read in a freshly signed build costs several seconds while
macOS evaluates the new signature against the key's ACL; every later read is
~2ms. Re-signing (which `build.sh` does on every build) resets that. So the
vault is opened on a background queue and folded into the data already on
screen — `store init: 1.2 ms` instead of 3.4 s, with payment details arriving
~50ms later warm, or after that one slow evaluation on the first run of a new
build. Until it opens, `saveNow()` writes data.json only and never touches
`vault.dat`, and anything already in memory (a migrated file, or an edit made
in the meantime) wins over what the vault holds. `--selftest-lazy-vault` checks
all of that.

Pagination measurements are memoised and run off the view-update path (debounced
200ms), because laying out a page costs a few milliseconds and doing that inside
`body` made every keystroke and selection change feel sluggish.
The window's minimum size is 1120×640 — that is the width at which the editor
form, the preview, and the sidebar all fit without clipping.
