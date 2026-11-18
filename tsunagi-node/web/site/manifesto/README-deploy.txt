TSUNAGI Manifesto Page Deployment
==================================

Publishing Model:
  This page is STATIC. All manifesto content is embedded directly in
  the HTML file. To update the manifesto, edit web/manifesto/index.html
  and redeploy the HTML file to the server.

  Future: If a markdown source is created at
  docs/manifesto/tsunagi-manifesto.md, the page could be converted
  to markdown-driven rendering (like the whitepaper page). For now,
  the static approach is appropriate given the manifesto's stable
  content and custom typography.

Deployment Steps:

1. Create directory:

   sudo mkdir -p /var/www/tsunagi/manifesto

2. Copy the HTML page:

   sudo cp web/manifesto/index.html /var/www/tsunagi/manifesto/index.html

3. Set permissions:

   sudo chown -R www-data:www-data /var/www/tsunagi/manifesto
   sudo chmod -R 755 /var/www/tsunagi/manifesto

4. Reload nginx:

   sudo nginx -t && sudo systemctl reload nginx

Verification:

   curl -I https://tsunagi.tech/manifesto/

Content Update Workflow:

   1. Edit web/manifesto/index.html in the repo
   2. Copy to server:
      sudo cp web/manifesto/index.html \
        /var/www/tsunagi/manifesto/index.html
   3. Reload nginx if needed

Notes:
- Fully self-contained HTML with inline CSS. No external dependencies.
- No JavaScript required.
- All content is statically embedded in the HTML file.
- Preferred future markdown path: /docs/manifesto/tsunagi-manifesto.md
