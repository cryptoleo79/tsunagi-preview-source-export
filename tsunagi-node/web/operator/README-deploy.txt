TSUNAGI Operator Page — Deployment Notes
=========================================

Page:    /operator/
Source:  web/operator/index.html
Model:   Fully static HTML

=== DEPLOYMENT ===

1. Create directory on server:

   sudo mkdir -p /var/www/tsunagi/operator

2. Copy to server:

   sudo cp web/operator/index.html \
     /var/www/tsunagi/operator/index.html

3. Reload nginx if needed:

   sudo nginx -t && sudo systemctl reload nginx

4. Verify deployment:

   curl -s -o /dev/null -w "%{http_code}" https://tsunagi.tech/operator/

=== CONTENT MODEL ===

This is a fully static page with no JavaScript and no external
data dependencies. All content is embedded in the HTML file.

To update content, edit web/operator/index.html and redeploy.

=== ASSET DEPENDENCY ===

None. This page uses no external images or data files.

=== SECTIONS ===

The page documents the following operator topics:

  1. Introduction         — Deterministic operation and operator visibility
  2. Operator Readiness   — Current operational state with status indicators
  3. Monitoring           — How operators observe TSUNAGI (/status, /explorer, /decode, etc.)
  4. Operational Workflow  — Daily operator verification flow (6-step sequence)
  5. Backups & Persistence — What to back up and recovery posture
  6. Interfaces           — Operational interfaces (runtime, status.json, web, future)
  7. Troubleshooting      — Operator philosophy (expose, reduce, legibility, observability)
  8. Current & Future     — Roadmap for operator tooling improvements
  9. Operator Snapshot    — Summary card with current operational state

See web/DEPLOY-TSUNAGI-SITE.txt for the full site deployment list.
