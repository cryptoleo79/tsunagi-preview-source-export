TSUNAGI Vision Page — Deployment Notes
========================================

Page:    /vision/
Source:  web/vision/index.html
Model:   Fully static HTML

=== DEPLOYMENT ===

1. Create directory on server:

   sudo mkdir -p /var/www/tsunagi/vision

2. Copy to server:

   sudo cp web/vision/index.html \
     /var/www/tsunagi/vision/index.html

3. Reload nginx if needed:

   sudo nginx -t && sudo systemctl reload nginx

=== CONTENT MODEL ===

This is a fully static page with no JavaScript and no external
data dependencies. All content is embedded in the HTML file.

The markdown source is maintained at:
  docs/vision/tsunagi-vision.md

To update content, edit both the markdown source and the HTML
page, then redeploy the HTML file.

=== MUSUBI CONCEPT ===

The page introduces MUSUBI (結び) as a long-term research direction
for connective infrastructure. This is intentionally framed as a
future research path, not a product or protocol specification.

Tone should remain visionary but restrained.
