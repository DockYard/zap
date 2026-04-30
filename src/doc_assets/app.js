/* Zap Documentation */
(function() {
  'use strict';

  // Dark mode
  var toggle = document.getElementById('theme-toggle');
  var html = document.documentElement;
  var saved = localStorage.getItem('zap-docs-theme');
  if (saved) {
    html.setAttribute('data-theme', saved);
  } else if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
    html.setAttribute('data-theme', 'dark');
  }
  if (toggle) {
    toggle.addEventListener('click', function() {
      var current = html.getAttribute('data-theme');
      var next = current === 'dark' ? 'light' : 'dark';
      html.setAttribute('data-theme', next);
      localStorage.setItem('zap-docs-theme', next);
    });
  }

  // Base path from meta tag
  var baseMeta = document.querySelector('meta[name="zap-docs-base"]');
  var basePath = baseMeta ? baseMeta.getAttribute('content') : '';

  // Search — data is inlined by the doc generator as ZAP_SEARCH_DATA
  var searchData = (typeof ZAP_SEARCH_DATA !== 'undefined') ? ZAP_SEARCH_DATA : null;
  var searchModal = document.getElementById('search-modal');
  var searchInput = document.getElementById('search-modal-input');
  var searchResults = document.getElementById('search-results');
  var sidebarInput = document.getElementById('search-input');
  var selectedIndex = -1;

  function openSearch() {
    searchModal.hidden = false;
    searchInput.value = '';
    searchResults.innerHTML = '';
    selectedIndex = -1;
    searchInput.focus();
  }

  function closeSearch() {
    searchModal.hidden = true;
  }

  function doSearch(query) {
    if (!searchData || !query) { searchResults.innerHTML = ''; return; }
    var q = query.toLowerCase();
    var matches = searchData.filter(function(item) {
      return item.name.toLowerCase().indexOf(q) !== -1 ||
             item.struct.toLowerCase().indexOf(q) !== -1 ||
             item.summary.toLowerCase().indexOf(q) !== -1;
    }).slice(0, 20);
    searchResults.innerHTML = matches.map(function(item, i) {
      return '<li data-url="' + basePath + item.url + '"' + (i === 0 ? ' class="selected"' : '') + '>' +
        '<div class="result-name">' + escapeHtml(item.name) + '</div>' +
        '<div class="result-struct">' + escapeHtml(item.struct) + ' &middot; ' + item.type + '</div>' +
        (item.summary ? '<div class="result-summary">' + escapeHtml(item.summary) + '</div>' : '') +
        '</li>';
    }).join('');
    selectedIndex = matches.length > 0 ? 0 : -1;
  }

  function escapeHtml(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  // Keyboard shortcuts
  document.addEventListener('keydown', function(e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      if (searchModal.hidden) openSearch(); else closeSearch();
    }
    if (e.key === 'Escape' && !searchModal.hidden) closeSearch();
    if (!searchModal.hidden) {
      var items = searchResults.querySelectorAll('li');
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        selectedIndex = Math.min(selectedIndex + 1, items.length - 1);
        items.forEach(function(li, i) { li.className = i === selectedIndex ? 'selected' : ''; });
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedIndex = Math.max(selectedIndex - 1, 0);
        items.forEach(function(li, i) { li.className = i === selectedIndex ? 'selected' : ''; });
      }
      if (e.key === 'Enter' && selectedIndex >= 0 && selectedIndex < items.length) {
        e.preventDefault();
        window.location.href = items[selectedIndex].getAttribute('data-url');
      }
    }
  });

  if (searchInput) {
    searchInput.addEventListener('input', function() { doSearch(this.value); });
  }
  if (sidebarInput) {
    sidebarInput.addEventListener('focus', function() { openSearch(); });
  }
  var backdrop = document.querySelector('.search-backdrop');
  if (backdrop) {
    backdrop.addEventListener('click', closeSearch);
  }
  if (searchResults) {
    searchResults.addEventListener('click', function(e) {
      var li = e.target.closest('li');
      if (li) window.location.href = li.getAttribute('data-url');
    });
  }

  // Scroll spy for TOC
  var tocLinks = document.querySelectorAll('.toc a');
  if (tocLinks.length > 0) {
    var observer = new IntersectionObserver(function(entries) {
      entries.forEach(function(entry) {
        if (entry.isIntersecting) {
          tocLinks.forEach(function(link) {
            link.parentElement.classList.remove('active');
            if (link.getAttribute('href') === '#' + entry.target.id) {
              link.parentElement.classList.add('active');
            }
          });
        }
      });
    }, { rootMargin: '-20% 0px -70% 0px' });
    document.querySelectorAll('.function-detail').forEach(function(el) {
      observer.observe(el);
    });
  }

  // Copy buttons on code blocks
  document.querySelectorAll('pre').forEach(function(pre) {
    var btn = document.createElement('button');
    btn.className = 'copy-btn';
    btn.textContent = 'Copy';
    btn.addEventListener('click', function() {
      var code = pre.querySelector('code');
      navigator.clipboard.writeText(code ? code.textContent : pre.textContent);
      btn.textContent = 'Copied!';
      setTimeout(function() { btn.textContent = 'Copy'; }, 2000);
    });
    pre.style.position = 'relative';
    pre.appendChild(btn);
  });
})();
