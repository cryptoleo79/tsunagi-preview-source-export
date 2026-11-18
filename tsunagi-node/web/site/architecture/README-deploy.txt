TSUNAGI Architecture Page — Deployment Notes
===============================================

Page:    /architecture/
Source:  web/architecture/index.html
Model:   Fully static HTML

=== DEPLOYMENT ===

1. Create directory on server:

   sudo mkdir -p /var/www/tsunagi/architecture

2. Copy to server:

   sudo cp web/architecture/index.html \
     /var/www/tsunagi/architecture/index.html

3. Reload nginx if needed:

   sudo nginx -t && sudo systemctl reload nginx

=== CONTENT MODEL ===

This is a fully static page with no JavaScript and no external
data dependencies. All content is embedded in the HTML file.

To update content, edit web/architecture/index.html and redeploy.

=== ASSET DEPENDENCY ===

The page references the architecture diagram image at:

  /assets/tsunagi-architecture.jpg

This asset must already be deployed at:

  /var/www/tsunagi/assets/tsunagi-architecture.jpg

See web/DEPLOY-TSUNAGI-SITE.txt for the full asset deployment list.

=== SUBSYSTEM REFERENCE ===

The page documents these subsystems:

  KAGAMI   — Diagnostics layer (mirror)
  YAMORI   — Guardian monitoring (guardian)
  TATE     — Fragment defense (shield)
  KURA     — Stabilization layer (storehouse)
  TSURUGI  — Protocol engine (blade)

Plus the deterministic ledger pipeline and LMDB persistent storage.
