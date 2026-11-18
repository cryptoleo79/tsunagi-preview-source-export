TSUNAGI Treasury Page Deployment
=================================

1. Create directory:

   sudo mkdir -p /var/www/tsunagi/treasury

2. Copy the HTML page:

   sudo cp web/treasury/index.html /var/www/tsunagi/treasury/index.html

3. Set permissions:

   sudo chown -R www-data:www-data /var/www/tsunagi/treasury
   sudo chmod -R 755 /var/www/tsunagi/treasury

4. Reload nginx:

   sudo nginx -t && sudo systemctl reload nginx

Verification:

   curl -I https://tsunagi.tech/treasury/

Notes:
- Fully self-contained HTML with inline CSS. No external dependencies.
- No JavaScript required (CSS animation only for status badge pulse).
- Placeholder info cards (Treasury Address, Pool Ticker, Pool ID,
  Support Handle) display "To be published" until operational details
  are finalized.
