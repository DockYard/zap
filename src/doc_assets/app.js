/* Zap Documentation */
(function() {
  'use strict';

  // Theme — dark is default per design; toggle persists user choice.
  // No system-preference sniffing.
  var toggle = document.getElementById('theme-toggle');
  var html = document.documentElement;
  var saved = localStorage.getItem('zap-docs-theme');
  html.setAttribute('data-theme', saved === 'light' ? 'light' : 'dark');
  if (toggle) {
    toggle.addEventListener('click', function() {
      var current = html.getAttribute('data-theme');
      var next = current === 'dark' ? 'light' : 'dark';
      html.setAttribute('data-theme', next);
      localStorage.setItem('zap-docs-theme', next);
    });
  }

  // Sidebar group collapse — chevron toggles on header click, state persists.
  var groupState = {};
  try { groupState = JSON.parse(localStorage.getItem('zap-docs-sidebar') || '{}'); } catch (e) {}
  document.querySelectorAll('.sidebar-group').forEach(function(group) {
    var key = group.getAttribute('data-group') || '';
    if (groupState[key] === true) group.setAttribute('data-collapsed', 'true');
    var header = group.querySelector('.sidebar-group-header');
    if (header) {
      header.addEventListener('click', function() {
        var collapsed = group.getAttribute('data-collapsed') === 'true';
        if (collapsed) group.removeAttribute('data-collapsed');
        else group.setAttribute('data-collapsed', 'true');
        groupState[key] = !collapsed;
        try { localStorage.setItem('zap-docs-sidebar', JSON.stringify(groupState)); } catch (e) {}
      });
    }
  });

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

  function rankScore(haystack, needle) {
    if (haystack.startsWith(needle)) return 0;
    if (haystack.indexOf(needle) !== -1) return 1;
    return 2;
  }

  function doSearch(query) {
    if (!searchData || !query) { searchResults.innerHTML = ''; return; }
    var q = query.toLowerCase();
    var scored = [];
    for (var i = 0; i < searchData.length; i++) {
      var item = searchData[i];
      var bestScore = Math.min(
        rankScore(item.name.toLowerCase(), q),
        rankScore(item.struct.toLowerCase(), q),
        item.summary ? rankScore(item.summary.toLowerCase(), q) : 2
      );
      if (bestScore < 2) scored.push({ item: item, score: bestScore });
    }
    scored.sort(function(a, b) { return a.score - b.score; });
    var matches = scored.slice(0, 12).map(function(x) { return x.item; });
    searchResults.innerHTML = matches.map(function(item, i) {
      var typeLabel = (item.type || '').toUpperCase();
      var label = item.struct && item.type === 'function' || item.type === 'macro'
        ? item.struct + '.' + item.name
        : item.name;
      var selected = i === 0;
      return '<li data-url="' + basePath + item.url + '"' + (selected ? ' class="selected"' : '') + '>' +
        '<span class="result-type">' + escapeHtml(typeLabel) + '</span>' +
        '<span class="result-name">' + escapeHtml(label) + '</span>' +
        (item.summary ? '<span class="result-summary">' + escapeHtml(item.summary) + '</span>' : '<span class="result-summary"></span>') +
        '<span class="result-enter">' + (selected ? '↵' : '') + '</span>' +
        '</li>';
    }).join('');
    selectedIndex = matches.length > 0 ? 0 : -1;
  }

  function updateSelectionStyles() {
    var items = searchResults.querySelectorAll('li');
    items.forEach(function(li, i) {
      li.className = i === selectedIndex ? 'selected' : '';
      var enter = li.querySelector('.result-enter');
      if (enter) enter.textContent = i === selectedIndex ? '↵' : '';
    });
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
        updateSelectionStyles();
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        selectedIndex = Math.max(selectedIndex - 1, 0);
        updateSelectionStyles();
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
