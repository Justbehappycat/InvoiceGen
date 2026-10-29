# InvoiceGen

A standalone, fully offline macOS app for making invoices in the same layout as the
Wave invoice this was modelled on. No account, no network, no subscription — all data
lives in a single JSON file on your Mac.

## Build & install

```bash
./build.sh
rm -rf /Applications/InvoiceGen.app && ditto build/InvoiceGen.app /Applications/InvoiceGen.app
```

Replace the installed app rather than copying over it. `cp -R` overwrites files in
place and reuses their inodes, so the kernel validates the new bytes against the
signature it already cached for that location and kills the app on launch with
`Invalid Page`. `ditto` onto a removed bundle avoids that and preserves xattrs.

Requires Xcode command line tools (Swift 5.9+). macOS 13 or newer.

## What it does

**Invoices**
- Banner template matching the sample invoice (accent color configurable) plus a Minimal template.
- Line items with description, quantity, price, per-line taxable flag.
- Discount (flat or %), tax at any rate, partial payments, amount due.
- Status: Draft / Sent / Paid, with automatic overdue flagging. Change it from
  the sidebar's right-click menu; "Mark as Paid" also settles the amount (⌘Z
  puts both back).
- **Archive and trash.** The filter menu switches the list between Invoices,
  Archive and Trash, with a count beside each. Archiving sets an invoice
  aside: it leaves the working list, stops counting toward the outstanding
  total, and can never be flagged overdue — but it stays in the customer's
  history, because the work still happened. The archive is filed by year,
  newest first.
- **Deleting is a move, not a destruction.** "Move to Trash" is reversible from
  the trash long after the undo history is gone; only "Delete Permanently" and
  "Empty Trash" actually remove anything. Trashed invoices drop out of customer
  history and the totals. An invoice opened from either pile says where it is
  and offers the way back.
- The sidebar leads with what still needs doing: overdue first, then unpaid by
  soonest due date, then paid — visible and searchable, just sunk to the bottom.
- "Today" beside the invoice date moves it to today and drags the due date with
  it, so a 30-day invoice stays a 30-day invoice.
- Duplicate any invoice, save one as a named template, or apply a template to the
  invoice you're editing (Reuse menu).
- Templates carry items, terms, tax, notes and payment details — not the customer
  or the dates. Start one from the sidebar's New menu; manage them in the Library.
- Clearing a number field means zero. SwiftUI's `TextField(value:format:)`
  parses on every keystroke and restores the old value when the parse fails —
  and an empty string is a failed parse, so deleting the last digit of "500"
  silently puts 500 back. Every number field here keeps the text as its state
  and lets the value follow: empty is zero, and a half-typed "1." leaves the
  field alone instead of fighting you. `--selftest-fields` covers it.
`--selftest-publish` checks the publishing contract without a network: that the
page metadata carries the summary and *not* payment details, that ids are
unguessable and unique, that the requests carry the bearer token, and that an
unconfigured or plain-http address refuses to publish at all.
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

**Projects** — one job, its schedule, and what it still owes
- Film and post work is billed per production, not per invoice. A project holds
  the client, what the contract is worth, the payment schedule and every invoice
  raised against it, and answers the question a single invoice cannot: what has
  been billed, what has been paid, and what is left.
- **The payment schedule is the contract.** Enter the dates it pays on —
  `Episode 1, $150, 30 Oct` / `Episodes 2-3, $300, 6 Nov` — and each line turns
  into a draft invoice on demand, carrying the deliverable as its line item, the
  milestone's date as its due date and the project's client as the customer.
- Drafts, never sends. "Invoice 3 unbilled" bills everything outstanding in one
  go, oldest due date first so the numbers run in the order the money is owed —
  and ⌘Z takes the whole batch back in a single step.
- **A milestone cannot be billed twice.** The schedule links to the invoice it
  produced, and the button is gone while that invoice exists.
- A trashed invoice releases its milestone. It stops counting toward the totals,
  so the schedule stops calling it billed and offers to raise it again —
  otherwise the screen contradicts itself, showing "Invoice #12" beside
  "$0.00 invoiced". Destroying an invoice for good unlinks it the same way.
- Trashed invoices drop out of the totals; archived ones still count, because
  the work happened and was billed.
- Deleting a project never deletes its invoices. They were real bills; they just
  stop belonging to a job.
- If the schedule doesn't add up to the contract total, the project says so
  rather than quietly disagreeing with itself.
- Projects are optional. An invoice with no project behaves exactly as before,
  and a data file written before projects existed opens untouched.
- `--selftest-project` covers all of it, including the undo batching and the
  pre-projects file.

**Import a contract** (needs the on-device model — see On-device assist)
- Projects ▸ New ▸ From a Contract… reads a contract PDF and proposes the
  client, the project and its whole payment schedule, so a job that arrives as
  a PDF is not typed in by hand.
- **Read on this Mac.** A contract is the most sensitive thing this app will
  ever open, so it goes to `SystemLanguageModel` and nowhere else. The build
  refuses the Private Cloud Compute model outright.
- **The model extracts; the app does the numbers.** Every amount and date comes
  back as text and is parsed here in `Decimal`. A payment whose amount or date
  cannot be read is not guessed at — it is listed under "Not used" so you can
  see what was left out. The contract total is summed by the app from the
  parsed amounts; the model is never asked for it.
- **Nothing is created until you say so.** Every field arrives editable in a
  review sheet. Creating is one undo step, and a client whose name already
  exists is reused rather than duplicated.
- Long contracts are trimmed to their opening and the paragraphs that mention
  money before they are read. A scanned contract has no text to read, and is
  refused with an explanation rather than handed to the model empty.
- `--selftest-contract` covers the parsing and its refusals with no model,
  reads a real generated PDF through PDFKit, and — where the model exists —
  extracts a four-payment schedule end to end.

**Invoice verification**
- **Stripes across the banner** (default, at 4%): the code runs the banner's full
  height behind the title — edge to edge, top and bottom — and nearly the full
  width of the coloured block, so a reading taken above or below the word
  crosses every column. The stripes print as a tint of the banner — a slider sets how
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
  number, invoice date, total quantity, total amount. The signature prints as
  eight decimal digits (`IG1-11-48219073`), and the bars encode digits only —
  four of invoice number, eight of signature. Code 128 packs two digits into
  one symbol, so an all-numeric payload halves the bar count: 106 bars instead
  of 216 across the same width, which is the difference between fine texture
  and deliberate stripes. 10^8 of signature is ample when forging one requires
  the passphrase regardless; the length only has to resist blind guessing. Change any one of them
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
- The key is **never** created except on a Mac that has no key *and* no vault.
  It used to be minted whenever a Keychain read failed — but a read fails for
  reasons that have nothing to do with the key being absent (most often a
  rebuilt binary whose signature no longer matches the item's ACL), and minting
  a replacement in that moment orphans a perfectly good vault, permanently.
  A failed read now reports "key unavailable", which destroys nothing and
  resolves itself the next time the app runs under the right identity.
- Writing the key is add-if-absent for the same reason: an update would
  overwrite the only copy that opens the existing vault. Replacing a key
  happens only through the explicit repair button.
- Self-tests that write get their own throwaway data directory, so no
  diagnostic can touch the real vault. That is not hypothetical: a headless
  test run under a different code signature is exactly how a vault got
  orphaned during development.
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

**On-device assist** (macOS 26 or later, Apple Intelligence on)
- "Tidy up wording" in a line item's menu rewrites shorthand into something a
  client reads cleanly: `ep1 edit + colour pass` / `long x1 short x1` becomes
  `Episode 1 Edit + Colour Pass` / `Long x1 Short x1`.
- **It runs on this Mac.** Apple's `SystemLanguageModel`, offline, no account,
  nothing sent anywhere. The same framework offers a Private Cloud Compute model
  that *would* send the text to Apple; it is never used, and `build.sh` refuses
  to build if its name appears outside a comment.
- **It rewords; it never re-prices.** Quantity, price and totals are untouched —
  the model is handed two text fields and returns two text fields. Any
  suggestion whose numbers differ from the input's, in either direction, is
  discarded rather than shown: inventing `$400` and quietly turning `ep1 edit`
  into `Episode Edit` are both failures, and the second was a real first draft.
- **Nothing is applied unseen.** The suggestion appears beside what you wrote,
  struck through, and you choose. Undo covers it like any other edit.
- The model fills a typed Swift value through guided generation, so there is no
  free text to parse and no malformed answer to handle.
- Turn it off in Settings. Below macOS 26 the framework is weak-linked and the
  feature is simply absent — the app still runs on macOS 13.
- `--selftest-assist` covers the number guard deterministically (no model
  needed) and, where a model exists, makes one real call and checks the
  contract rather than the prose.

## Checking the interface without the vault

A copy of the app that isn't signed with the Developer ID -- an ad-hoc test
build, say -- isn't on the vault key's Keychain access list, so every launch
asks for a password. For looking at the interface, run it in UI-check mode:

```bash
INVOICEGEN_UI_CHECK=1 INVOICEGEN_DATA=/path/to/fixture.json build/InvoiceGen.app/Contents/MacOS/InvoiceGen --appearance dark
```

The vault and the Keychain are never touched, so nothing prompts. It refuses
to switch on without an explicit fixture file, and refuses outright if that
file is the real data file. It never saves, so nothing can be written in the
clear, and the Dock icon says "UI". `--appearance light|dark` sets the theme
for that copy alone. `--selftest-uicheck` checks every refusal and, run in
the mode, that the Keychain returns nothing and a save writes nothing.

Look at the live window rather than `--render-ui` for the toolbar and the
sidebar selection: an offscreen render can't draw the glass materials or the
selection, and shows them as faint or black when they are fine.

## Publishing an invoice as a link

> Off, and nothing is deployed. The Worker that served `invoice.finecut.com`
> has been deleted. Publishing stays dormant until an address and token are set
> in Settings ▸ Publishing, so the Share menu simply says so and does nothing.

**Share** on an invoice publishes it to `invoice.finecut.com` and copies the
link to the clipboard, so a client gets a URL instead of an attachment. The
same menu updates the published copy or unpublishes it.

- Nothing leaves this Mac until you press Share, and only two things do then:
  the PDF you would have emailed, and a short summary for the page around it —
  number, dates, amount due, status. Payment details are not in that summary;
  they stay inside the PDF.
- A link is a capability: 12 random hex characters that anyone holding the URL
  can open. That is what makes it work for a client with no account. Treat the
  link like the invoice, and unpublish when the job is done.
- Re-publishing keeps the same link, so a client's bookmark keeps working.
- The endpoint address lives in `data.json`; the bearer token lives in the
  login Keychain, never on disk in the clear.
- The Worker, its tests and the deployment steps are in [`web/`](web/README.md).

## Updates

The app can update itself from GitHub Releases, so a fix pushed from one Mac
reaches the others without copying bundles around by hand.

Cutting a release — bump `VERSION`, commit, then:

```
./release.sh
```

That builds, signs, zips with `ditto`, re-verifies the signature after the zip
round-trip, tags, and publishes the release with notes taken from the commits
since the last tag (or `RELEASE_NOTES` if set).

On the receiving end the app checks at most once a day, in the background, four
seconds after launch so a slow network can never delay the window. A background
check that cannot reach GitHub stays silent — an offline app should not nag
about being offline. `InvoiceGen ▸ Check for Updates…` always asks regardless,
and reports being up to date. Settings ▸ Updates turns the automatic check off.

Nothing installs on its own. You are shown the version and its notes, and the
download only starts if you agree.

### Why this is safe to have at all

An updater is a remote code execution channel into a machine holding your
payment details, so the whole design rests on one check: the downloaded bundle
must satisfy

```
identifier "com.finecut.invoicegen" and anchor apple generic
  and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */
  and certificate leaf[subject.OU] = "T7R6S9637T"
```

That requirement is not written down in the source. It is *derived at runtime
from the running app's own signature*, so it cannot drift away from the real
identity, and a build that is unsigned or ad-hoc refuses to self-update at all
rather than installing code it cannot check. The check runs before anything is
installed, uses `kSecCSCheckNestedCode` so it covers everything inside the
bundle rather than just the main executable, and a failure discards the
download.

Three further constraints:

- The asset must be a `.zip` served over HTTPS from a `github.com` host.
- Extraction uses `ditto`, not `unzip`, which discards the extended attributes
  carrying the signature and would make every download look tampered with.
- The verified bundle must also *claim* a newer version in its own Info.plist,
  so an older release cannot be replayed at you.

`--selftest-update` exercises all of it, including copying the running app,
editing a byte of its Info.plist, and confirming the check rejects the result.
Run it from the built bundle, not `.build/release`, since an unbundled binary
has no signature to derive from.

The only thing the check leaks is that some IP address asked GitHub for the
latest release, once a day.

### Notarization is not optional

Developer ID signing alone is not enough. When a file arrives with a quarantine
flag -- which anything downloaded through a browser has -- Gatekeeper asks Apple
whether the app was notarized, and refuses an unnotarized one outright:

> "InvoiceGen.app" Not Opened. Apple could not verify "InvoiceGen.app" is free
> of malware that may harm your Mac or compromise your privacy.

So `release.sh` notarizes, staples the ticket to the bundle, and then
*repackages* -- stapling modifies the app, so a zip built before it carries no
ticket. It then checks the packaged copy with `spctl` and refuses to publish
unless Gatekeeper reports `source=Notarized Developer ID`. Stapling is what
makes that check work without a network round trip on the receiving Mac.

Credentials come from a notarytool keychain profile, never from the repo:

```
xcrun notarytool store-credentials "InvoiceGen" \
  --apple-id <your-apple-id> --team-id T7R6S9637T
```

`NOTARY_PROFILE` picks a different profile name. `SKIP_NOTARIZE=1` publishes
without it, which is only ever right for a build that stays on this Mac.

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

## Reviewed against swiftui-pro

The codebase was audited with the [swiftui-pro](https://github.com/twostraws/swiftui-agent-skill)
agent skill, keeping the rules that apply to a macOS app and checking each
claimed deprecation against the SDK's `.swiftinterface` rather than taking the
rule's word for it. Applied: labels on every icon-only control, `foregroundStyle`
throughout, `clipShape(.rect(cornerRadius:))`, `Task.sleep(for:)`, and
cancellable `Task` debounces in place of `DispatchWorkItem`.

Deliberately not applied:

- **Dynamic Type in the printed document.** `InvoiceDocumentView` sets fixed
  point sizes because it renders a 612×792pt US Letter page. Type that reflowed
  with the reader's accessibility settings would break pagination and the PDF.
- **One type per file.** `Models.swift` holds one coherent domain.
- **Extracting every computed `some View` into its own struct.** Style, and it
  would scatter cohesive sections across dozens of files.
- **The single-parameter `onChange`.** Genuinely deprecated (macOS 14), but the
  two-parameter form is macOS 14+ and this package targets macOS 13. It is a
  deployment-target decision, not a code fix — which is also why the build shows
  no warning for it.

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
`--selftest-archive` checks that archiving removes an invoice from the working
list but not from the customer's history, that deleting only moves it to the
trash, that undo un-deletes, that emptying really removes, and that the archive
groups by year newest-first.
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
