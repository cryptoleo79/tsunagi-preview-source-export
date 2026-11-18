TSUNAGI Labs — Deployment Notes
================================

Location:  /var/www/tsunagi/labs/
File:      index.html

Deploy:
  cp web/labs/index.html /var/www/tsunagi/labs/index.html

Nginx:
  No additional configuration needed.
  Served by existing catch-all: try_files $uri $uri/ =404;

Verify:
  curl -s -o /dev/null -w "%{http_code}" https://tsunagi.tech/labs/
  # Expect: 200
