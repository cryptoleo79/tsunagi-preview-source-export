TSUNAGI Roadmap Page Deployment
================================

Publishing Model:
  This page is STATIC. All roadmap content (phases, status badges,
  verification criteria) is embedded directly in the HTML file. To
  update roadmap content or phase status, edit web/roadmap/index.html
  and redeploy the HTML file to the server.

  Future: If a markdown source is created at
  docs/roadmap/tsunagi-roadmap.md, the page could be converted to
  markdown-driven rendering. For now, the static approach is
  appropriate given the roadmap's card-based layout with color-coded
  phase badges, which benefit from direct HTML control.

Deployment Steps:

1. Create directory:

   sudo mkdir -p /var/www/tsunagi/roadmap

2. Copy the HTML page:

   sudo cp web/roadmap/index.html /var/www/tsunagi/roadmap/index.html

3. Set permissions:

   sudo chown -R www-data:www-data /var/www/tsunagi/roadmap
   sudo chmod -R 755 /var/www/tsunagi/roadmap

4. Reload nginx:

   sudo nginx -t && sudo systemctl reload nginx

Verification:

   curl -I https://tsunagi.tech/roadmap/

Content Update Workflow:

   1. Edit web/roadmap/index.html in the repo
   2. Copy to server:
      sudo cp web/roadmap/index.html \
        /var/www/tsunagi/roadmap/index.html
   3. Reload nginx if needed

Notes:
- Fully self-contained HTML with inline CSS. No external dependencies.
- No JavaScript required.
- Phase status badges: Complete (green), In Progress (yellow), Planned (blue).
- Preferred future markdown path: /docs/roadmap/tsunagi-roadmap.md
