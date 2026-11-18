TSUNAGI Whitepaper (HTML) Deployment
=====================================

Publishing Model:
  This page is MARKDOWN-DRIVEN. The HTML shell is static, but the
  whitepaper body is fetched at runtime from a markdown file on the
  server. To update the whitepaper content, edit the markdown source
  and copy it to the server. No HTML changes are needed.

  Content source:  /docs/whitepaper/tsunagi-whitepaper.md
  Rendered by:     inline JavaScript in web/whitepaper/index.html

  Updating the markdown file on the server updates the website
  automatically on the next page load.

Prerequisites:
- nginx installed and running
- Main site (tsunagi.tech) deployed

Deployment Steps:

1. Create directories:

   sudo mkdir -p /var/www/tsunagi/whitepaper
   sudo mkdir -p /var/www/tsunagi/docs/whitepaper

2. Copy the HTML page:

   sudo cp web/whitepaper/index.html /var/www/tsunagi/whitepaper/index.html

3. Copy the whitepaper markdown source (fetched by the HTML page):

   sudo cp docs/whitepaper/tsunagi-whitepaper.md /var/www/tsunagi/docs/whitepaper/tsunagi-whitepaper.md

4. Copy the PDF (linked from Download PDF button):

   sudo cp docs/whitepaper/tsunagi-whitepaper-v1.pdf /var/www/tsunagi/docs/whitepaper/tsunagi-whitepaper-v1.pdf

5. Ensure the architecture image is deployed:

   sudo cp docs/public/images/tsunagi-architecture.jpg /var/www/tsunagi/assets/tsunagi-architecture.jpg

6. Set permissions:

   sudo chown -R www-data:www-data /var/www/tsunagi
   sudo chmod -R 755 /var/www/tsunagi

7. Reload nginx:

   sudo nginx -t && sudo systemctl reload nginx

Verification:

   curl -I https://tsunagi.tech/whitepaper/
   curl -I https://tsunagi.tech/docs/whitepaper/tsunagi-whitepaper.md

Required server paths:

   /var/www/tsunagi/whitepaper/index.html
   /var/www/tsunagi/docs/whitepaper/tsunagi-whitepaper.md    <- publishing source
   /var/www/tsunagi/docs/whitepaper/tsunagi-whitepaper-v1.pdf
   /var/www/tsunagi/assets/tsunagi-architecture.jpg

Content Update Workflow:

   1. Edit docs/whitepaper/tsunagi-whitepaper.md in the repo
   2. Copy to server:
      sudo cp docs/whitepaper/tsunagi-whitepaper.md \
        /var/www/tsunagi/docs/whitepaper/tsunagi-whitepaper.md
   3. Refresh the page — new content appears immediately

Notes:
- The page renders the markdown source via inline JavaScript.
- The static HTML shell includes: title block, abstract, list of
  figures, and full table of contents — all rendered without JS.
- The markdown file must be accessible at the same origin under
  /docs/whitepaper/tsunagi-whitepaper.md
- Architecture image is rewritten from relative markdown path to
  /assets/tsunagi-architecture.jpg
- No external dependencies. Fully self-contained inline CSS + JS.
