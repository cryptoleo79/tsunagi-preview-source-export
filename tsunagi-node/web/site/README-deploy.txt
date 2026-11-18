TSUNAGI Website Deployment
==========================

Prerequisites:
- nginx installed and running
- DNS for tsunagi.tech pointing to the server
- SSL certificate configured (recommended: certbot/Let's Encrypt)

Deployment Steps:

1. Create the web root directory:

   sudo mkdir -p /var/www/tsunagi
   sudo mkdir -p /var/www/tsunagi/assets

2. Copy the landing page:

   sudo cp web/index.html /var/www/tsunagi/index.html

3. Copy the architecture image:

   sudo cp docs/public/images/tsunagi-architecture.jpg /var/www/tsunagi/assets/tsunagi-architecture.jpg

4. Set permissions:

   sudo chown -R www-data:www-data /var/www/tsunagi
   sudo chmod -R 755 /var/www/tsunagi

5. Reload nginx:

   sudo nginx -t && sudo systemctl reload nginx

Verification:

   curl -I https://tsunagi.tech/
   curl -I https://tsunagi.tech/assets/tsunagi-architecture.jpg

Notes:

- The index.html is fully self-contained with inline CSS and JavaScript.
- No external CDN assets or frameworks are required.
- The architecture image is the only external asset referenced by the page.
- All navigation links use placeholder anchors (#whitepaper, #manifesto, etc.)
  and should be updated to real URLs when the documents are published.
