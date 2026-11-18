TSUNAGI Status Page Deployment
================================

1. Create directory:

   sudo mkdir -p /var/www/tsunagi/status

2. Copy the HTML page:

   sudo cp web/status/index.html /var/www/tsunagi/status/index.html

3. Generate status.json:

   The status page fetches /status.json via XHR every 10 seconds.
   Use the generator script to produce this file from node state:

   TSUNAGI_HOME=~/tsunagi-home-preview \
     ./scripts/generate-status-json.sh /var/www/tsunagi/status.json

   See scripts/README-status-json.txt for full documentation,
   automation options (cron, systemd timer), and field explanations.

4. Configure nginx for /status.json:

   Add to your server block:

     location = /status.json {
         root /var/www/tsunagi;
         default_type application/json;
         add_header Cache-Control "no-cache, no-store, must-revalidate";
         add_header Pragma "no-cache";
         add_header Expires "0";
         add_header Access-Control-Allow-Origin "*";
     }

   The no-cache headers ensure browsers always fetch the latest data.

5. Set permissions:

   sudo chown -R www-data:www-data /var/www/tsunagi/status
   sudo chmod -R 755 /var/www/tsunagi/status
   sudo chown www-data:www-data /var/www/tsunagi/status.json

6. Reload nginx:

   sudo nginx -t && sudo systemctl reload nginx

Verification:

   curl -I https://tsunagi.tech/status/
   curl -s https://tsunagi.tech/status.json | head -20

Expected JSON shape:

   {
     "network": "preview",
     "slot": 106652560,
     "block": 4100813,
     "tip_hash": "496a6c4ba53d82a9",
     "fwd": 146,
     "back": 27,
     "utxo": 10,
     "tps": null,
     "shadow_enabled": true,
     "primary_mode": "lmdb_truth",
     "status": "healthy",
     "updated_at": "2026-03-13T00:00:00Z",
     "tx_count": 6,
     "utxo_consumed": null,
     "utxo_produced": null,
     "utxo_delta": null,
     "coverage_found": null,
     "coverage_total": 15,
     "fallback_used": null,
     "tip_age_seconds": 3
   }

Notes:
- Fully self-contained HTML with inline CSS and JavaScript.
- No external dependencies or frameworks.
- Auto-refreshes every 10 seconds via XHR to /status.json.
- Graceful error handling: if status.json is unavailable, the page
  shows a "Status unavailable" banner and continues retrying.
- Health styling: healthy (green), warning (amber), critical (red).
- Cards grouped into: Chain, Ledger, Persistence, Health.
- Missing JSON fields display as em-dash (—).
- Tip age color-coded: <120s green, 120-600s amber, >600s red.
