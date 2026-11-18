(function(){
  var c = document.getElementById('nav-container');
  if (!c) return;
  var xhr = new XMLHttpRequest();
  xhr.open('GET', '/partials/nav.html', true);
  xhr.timeout = 3000;
  xhr.onload = function() {
    if (xhr.status >= 200 && xhr.status < 300) {
      c.innerHTML = xhr.responseText;
      // Highlight current page link
      var path = location.pathname;
      var links = c.querySelectorAll('.ub-nav a');
      for (var i = 0; i < links.length; i++) {
        var href = links[i].getAttribute('href');
        if (href && href !== '/' && path.indexOf(href) === 0) {
          links[i].style.color = '#eceef3';
          links[i].style.borderColor = 'rgba(80,140,220,0.35)';
        }
      }
    }
  };
  xhr.send();
})();
