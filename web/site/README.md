# Landing page

Static page for InvoiceGen. No build step — plain HTML, one stylesheet inline,
two images. Open `index.html`, or serve the folder:

    python3 -m http.server 8787 --directory web/site/public

**Not deployed.** Nothing is published at invoice.finecut.com.

## The screenshot

`public/assets/screenshot-invoices.png` must never be regenerated against the real
data file: it would put real clients, their email addresses and the business
address straight onto a public page. Render it against seeded data instead:

    INVOICEGEN_DATA=/tmp/demo/data.json \
      build/InvoiceGen.app/Contents/MacOS/InvoiceGen \
      --render-ui web/site/public/assets/screenshot-invoices.png 1440 900 invoices

`INVOICEGEN_DATA` is the override the app actually honours. Setting `HOME`
does **not** work — `NSHomeDirectory()` ignores it and the app reads the real
file anyway. Always look at the resulting image before committing it.

## Version numbers

The download link uses `releases/latest/download/...`, so it follows new
releases on its own. The version and size printed next to it are hard-coded
and go stale — update them when cutting a release, or teach `release.sh` to
rewrite them.
