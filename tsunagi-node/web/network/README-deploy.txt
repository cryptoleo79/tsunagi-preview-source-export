TSUNAGI Network Page — Deployment Notes
=========================================

Page:    /network/
Source:  web/network/index.html
Model:   Fully static HTML (scaffold)

=== DEPLOYMENT ===

1. Create directory on server:

   sudo mkdir -p /var/www/tsunagi/network

2. Copy to server:

   sudo cp web/network/index.html \
     /var/www/tsunagi/network/index.html

3. Reload nginx if needed:

   sudo nginx -t && sudo systemctl reload nginx

=== CONTENT MODEL ===

This is currently a fully static scaffold page with no JavaScript
and no external data dependencies.

When multi-node telemetry becomes available, this page will be
updated to fetch and aggregate data from multiple /status.json
endpoints.

=== CURRENT STATE ===

The page honestly communicates that multi-node telemetry is not
yet active. Future dashboard cards are displayed with dashed
borders and reduced opacity to clearly indicate placeholder state.

=== FUTURE EVOLUTION ===

When ready, this page will:
  1. Fetch /status.json from registered TSUNAGI node endpoints
  2. Aggregate health, coverage, and tip data
  3. Display network-wide metrics
  4. Highlight anomalies and unhealthy nodes

No timeline is promised for this evolution.
