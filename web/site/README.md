# Landing page

Static page for InvoiceGen. No build step — plain HTML, one stylesheet inline,
and its images. Open `index.html`, or serve the folder:

    python3 -m http.server 8787 --directory web/site/public

Published at invoice.finecut.com by running `npx wrangler deploy` in `web/site`.

## The screenshots

The images in `public/assets/` are published, so they must never show real
clients, contracts or addresses. Make them from invented data:

    build/InvoiceGen.app/Contents/MacOS/InvoiceGen --demo-shots <folder>

That data lives only in memory and never touches the real data file. Always
look at the resulting images before committing them. See "Screenshots for the
README and the website" in `docs/DETAILS.md`.

## Version numbers

The download link uses `releases/latest/download/...`, so it follows new
releases on its own. The version and size printed next to it are hard-coded
and go stale — update them when cutting a release, or teach `release.sh` to
rewrite them.
