TSUNAGI Install Page — Deployment Notes
=========================================

Page:    /install/
Source:  web/install/index.html
Model:   Fully static HTML

=== DEPLOYMENT ===

1. Create directory on server:

   sudo mkdir -p /var/www/tsunagi/install

2. Copy to server:

   sudo cp web/install/index.html \
     /var/www/tsunagi/install/index.html

3. Reload nginx if needed:

   sudo nginx -t && sudo systemctl reload nginx

=== CONTENT MODEL ===

This is a fully static page with no JavaScript and no external
data dependencies. All content is embedded in the HTML file.

To update content, edit web/install/index.html and redeploy.

=== NOTES ===

Installation commands shown on this page are placeholder examples.
As the project evolves, update the commands to reflect the current
build and runtime workflow.
