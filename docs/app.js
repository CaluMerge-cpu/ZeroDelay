// ZeroDelay site: fills the download box and the change list from GitHub's public releases (no key needed),
// moves the glass highlight with the pointer, and fades sections in on scroll.
(() => {
  const REPO = 'CaluMerge-cpu/ZeroDelay';
  const $ = (id) => document.getElementById(id);

  const fmtSize = (b) => b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.round(b / 1024) + ' KB';
  const fmtDate = (s) => new Date(s).toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: 'numeric' });
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // a small Markdown reader for release notes: headings, lists, bold, code, links, paragraphs
  function md(src) {
    const inline = (t) => esc(t)
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
      .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" rel="noopener">$1</a>');
    const out = []; let list = 0; let para = [];
    const flush = () => { if (para.length) { out.push('<p>' + inline(para.join(' ')) + '</p>'); para = []; } };
    const closeLists = (to) => { while (list > to) { out.push('</ul>'); list--; } };
    for (const raw of src.replace(/\r/g, '').split('\n')) {
      const line = raw.replace(/\s+$/, '');
      const h = line.match(/^(#{1,4})\s+(.*)$/);
      const li = line.match(/^(\s*)[-*]\s+(.*)$/);
      if (h) { flush(); closeLists(0); out.push('<h4>' + inline(h[2]) + '</h4>'); }
      else if (li) {
        flush();
        const depth = Math.floor(li[1].length / 2) + 1;
        while (list < depth) { out.push('<ul>'); list++; }
        closeLists(depth);
        out.push('<li>' + inline(li[2]) + '</li>');
      }
      else if (!line.trim()) { flush(); closeLists(0); }
      else { closeLists(0); para.push(line.trim()); }
    }
    flush(); closeLists(0);
    return out.join('');
  }

  async function load() {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=6`, { headers: { Accept: 'application/vnd.github+json' } });
      if (!res.ok) throw new Error(res.status);
      const rels = (await res.json()).filter((r) => !r.draft && !r.prerelease);
      if (!rels.length) throw new Error('none');
      const latest = rels[0];
      const asset = (latest.assets || []).find((a) => /\.exe$/i.test(a.name));
      if (asset) {
        $('dl').href = asset.browser_download_url;
        $('size').textContent = fmtSize(asset.size);
      }
      $('ver').textContent = 'Version ' + latest.tag_name.replace(/^v/, '');
      $('date').textContent = fmtDate(latest.published_at);
      const sha = (latest.body || '').match(/SHA-256:\s*`?([A-Fa-f0-9]{64})`?/);
      if (sha) { $('hash').textContent = sha[1].toUpperCase(); $('hashrow').hidden = false; }

      $('releases').innerHTML = rels.slice(0, 5).map((r, i) => {
        const body = (r.body || '').split(/\n##\s+Install or update/i)[0];
        return `<article class="rel glass">
          <header><h3>${esc(r.name || r.tag_name)}</h3><time datetime="${r.published_at}">${fmtDate(r.published_at)}</time>${i === 0 ? '<span class="tag latest">Latest</span>' : ''}</header>
          <div class="body">${md(body)}</div>
          <button class="more" type="button">Read more</button>
        </article>`;
      }).join('');
      document.querySelectorAll('.rel').forEach((el) => {
        const b = el.querySelector('.more'), body = el.querySelector('.body');
        if (body.scrollHeight <= body.clientHeight + 4) { b.remove(); body.style.setProperty('--x', '0'); el.classList.add('open'); return; }
        b.addEventListener('click', () => { const o = el.classList.toggle('open'); b.textContent = o ? 'Show less' : 'Read more'; });
      });
      bindGlass();
    } catch (e) {
      $('releases').innerHTML = `<p class="muted">The release list could not be loaded right now. <a href="https://github.com/${REPO}/releases">See all releases on GitHub</a>.</p>`;
    }
  }

  // copy the checksum
  $('copy').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText($('hash').textContent); $('copy').textContent = 'Copied'; setTimeout(() => { $('copy').textContent = 'Copy'; }, 1600); } catch (e) {}
  });

  // the glass highlight follows the pointer
  function bindGlass() {
    document.querySelectorAll('.glass').forEach((el) => {
      if (el.dataset.g) return; el.dataset.g = '1';
      el.addEventListener('pointermove', (ev) => {
        const r = el.getBoundingClientRect();
        el.style.setProperty('--mx', (ev.clientX - r.left) + 'px');
        el.style.setProperty('--my', (ev.clientY - r.top) + 'px');
      });
    });
  }
  bindGlass();

  // sections fade in as they come into view
  const io = 'IntersectionObserver' in window ? new IntersectionObserver((es) => {
    es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { rootMargin: '0px 0px -8% 0px' }) : null;
  document.querySelectorAll('.reveal').forEach((el) => io ? io.observe(el) : el.classList.add('in'));

  load();
})();
