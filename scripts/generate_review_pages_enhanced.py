#!/usr/bin/env python3
"""
generate_review_pages_enhanced.py — Review pages for Enhanced pricing pipeline.

Generates (no Auto-Match Review):
  contact_sheet.html   — All pins grid, filter buttons, price desc
  new_ctm.html         — ClickToMatch v2 (confidence-sorted queue, DINOv2 pre-select)
  nts_review.html      — Slot Review (matched pins with selected slot > 0 only)
  new_ctp.html         — ClickToPrice v2 (supports ?filter=no_match from CTM done link)

Usage:
    python3 generate_review_pages_enhanced.py <path_to_PriceCollection_folder> [--firebase-export path.json]
"""
import json, pathlib, sys, re, base64 as _b64

# ── Category keywords ─────────────────────────────────────────────────────
_CAT_KW = {
    'hidden': ['hidden disney', 'hidden mickey', 'hidden character'],
    'wdi':    ['wdi', 'mog', "mickey's of glendale", 'mickeys of glendale'],
    'dec':    ['dec', 'wdcs', 'walt disney company store', 'disney employee center'],
    'dssh':   ['dssh', 'dsf', 'disney soda fountain', 'disney studio store hollywood'],
    'le':     ['limited edition'],
}

def _cats(title: str) -> list:
    t = title.lower()
    result = []
    for cat, kws in _CAT_KW.items():
        if any(k in t for k in kws):
            result.append(cat)
    if 'le' not in result and re.search(r'\ble\b', t):
        result.append('le')
    return result

def _price(c: dict) -> float:
    # Item price without shipping — buyers pay shipping either way (Whatnot or
    # eBay), so the pin-only price is the comparable number across listings.
    v = c.get('price') or c.get('total_price') or 0
    try: return float(v)
    except: return 0.0

def _extract_firebase(idx_path: pathlib.Path):
    # Prefer ui_data.json / ui_data_reranked.json — always freshly generated
    # with the correct test_run_id for this run.  The index.html may have been
    # copied from a prior run as a template and still carry a stale ID.
    ui_dir = idx_path.parent
    for ui_fname in ('ui_data_reranked.json', 'ui_data.json'):
        ui_path = ui_dir / ui_fname
        if ui_path.exists():
            try:
                ui = json.loads(ui_path.read_text(encoding='utf-8'))
                tri = ui.get('test_run_id', '')
                api = ui.get('approach_id', 'visual_baseline')
                fb  = ui.get('firebase') or {}
                if tri:
                    print(f'  Firebase: test_run_id from {ui_fname}: {tri}')
                    return fb, tri, api
            except Exception as e:
                print(f'  WARN: {ui_fname} read failed: {e}')

    # Fallback: extract from embedded b64 in index.html
    html = idx_path.read_text(encoding='utf-8')
    chunks = re.findall(
        r'<script[^>]*class="embedded-ui-b64-chunk"[^>]*data-chunk-index="(\d+)"[^>]*>(.*?)</script>',
        html, re.DOTALL)
    if chunks:
        chunks.sort(key=lambda x: int(x[0]))
        b64 = ''.join(c[1].strip() for c in chunks)
    else:
        m = re.search(r'id="embedded-ui-data-b64"[^>]*>(.*?)</script>', html, re.DOTALL)
        b64 = m.group(1).strip() if m else ''
    if b64:
        try:
            payload = json.loads(_b64.b64decode(b64).decode('utf-8'))
            return (payload.get('firebase') or {},
                    payload.get('test_run_id', ''),
                    payload.get('approach_id', 'visual_baseline'))
        except Exception as e:
            print(f'  WARN: firebase extract failed: {e}')
    return {}, '', 'visual_baseline'

def _embed_thumbnails(pins: list, crop_dir: pathlib.Path, size: int = 120) -> None:
    """Resize each crop to a small thumbnail and embed as base64 data URI."""
    try:
        from PIL import Image
        import io, base64 as _b64lib
    except ImportError:
        print('  WARN: Pillow not available — crops will use relative paths')
        for p in pins: p['crop_b64'] = ''
        return
    ok = 0
    for p in pins:
        fname = p.get('crop', '')
        path = crop_dir / fname if fname else None
        if not path or not path.exists():
            p['crop_b64'] = ''
            continue
        try:
            img = Image.open(path).convert('RGB')
            img.thumbnail((size, size), Image.LANCZOS)
            buf = io.BytesIO()
            img.save(buf, 'JPEG', quality=72, optimize=True)
            p['crop_b64'] = 'data:image/jpeg;base64,' + _b64lib.b64encode(buf.getvalue()).decode()
            ok += 1
        except Exception:
            p['crop_b64'] = ''
    print(f'  Embedded {ok}/{len(pins)} crop thumbnails')


def _build_pins(data: dict, scores: dict, orig_dp: dict = None) -> list:
    """Build pin list with DINOv2 best_slot for pre-selection (score-only pipeline)."""
    pins = []
    orig_dp = orig_dp or {}
    for board in data.get('boards', []):
        for pin in board.get('pins', []):
            cands = pin.get('candidates', [])
            cl = [{'p': _price(c),
                   'thumb': c.get('thumbUrl') or c.get('thumb_url') or '',
                   'title': (c.get('title') or '')[:80],
                   'url': c.get('itemUrl') or '',
                   **({'src': 'history',
                       'hdate': c.get('_hist_date') or '',
                       'hsim': c.get('_dino_sim')} if c.get('_src') == 'history' else {})}
                  for c in cands]
            slot0_p = cl[0]['p'] if cl else 0
            alts = [c['p'] for c in cl[1:] if c['p'] > 0]
            cheapest = min(alts) if alts else slot0_p
            sc = scores.get(pin['pin_key'], {})
            best_slot = sc.get('best_slot')
            best_sim = sc.get('best_sim')
            margin = sc.get('margin')
            tier = sc.get('confidence_tier') or 'unknown'
            title = pin.get('listing_title') or (cl[0]['title'] if cl else '')
            ms = pin.get('match_status') or 'unreviewed'
            # Pre-select DINOv2 best candidate for display (never auto-confirm).
            if best_slot is not None and 0 <= best_slot < len(cl):
                show_slot = best_slot
            else:
                show_slot = 0
            best_dp = cl[show_slot]['p'] if cl and show_slot < len(cl) else slot0_p
            show_thumb = cl[show_slot]['thumb'] if cl and show_slot < len(cl) else (cl[0]['thumb'] if cl else '')
            pins.append({
                'pk':      pin['pin_key'],
                'crop':    pin.get('crop_filename') or '',
                'board_num': str(board.get('board_num') or pin.get('board_num') or ''),
                'pin_n':   int(pin.get('pin_n') or 0),
                'price':   float(best_dp or slot0_p),
                'title':   title,
                'thumb':   show_thumb,
                'cands':   cl,
                'slot0_p': slot0_p,
                'cheapest':cheapest,
                'var':     round(slot0_p - cheapest, 2),
                'best_slot': best_slot,
                'best_sim':  best_sim,
                'margin':    margin,
                'confidence_tier': tier,
                'show_slot': show_slot,
                'cats':    _cats(title),
                'ms':      ms,
            })
    return pins

# ── Shared snippets ───────────────────────────────────────────────────────
_GRAY_PLACEHOLDER = (
    "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmci"
    "IHdpZHRoPSIxMjAiIGhlaWdodD0iMTIwIj48cmVjdCB3aWR0aD0iMTIwIiBoZWlnaHQ9IjEyMCIg"
    "ZmlsbD0iIzIyMiIvPjx0ZXh0IHg9IjYwIiB5PSI2OCIgZm9udC1zaXplPSIzNiIgdGV4dC1hbmNo"
    "b3I9Im1pZGRsZSIgZmlsbD0iIzU1NSI+PzwvdGV4dD48L3N2Zz4="
)

_FB_SDK = '''\
<script>
// Firebase REST API — no SDK required, anonymous reads/writes via fetch()
// Works regardless of network conditions or Firebase SDK availability.
const _DB_BASE = (typeof FB_CFG !== 'undefined' && FB_CFG && FB_CFG.databaseURL)
  ? FB_CFG.databaseURL.replace(/\/+$/, '')
  : 'https://fins-and-pins-click-to-claim-default-rtdb.firebaseio.com';

function _rtdbPath(pk) {
  // Replace ALL non-alphanumeric chars (except _ and -) so RTDB key is always valid
  return 'pin_pricing_tests/' + TEST_RUN_ID + '/' + APPROACH_ID + '/pins/'
       + pk.replace(/[^A-Za-z0-9_-]/g, '_');
}
function _getUser() {
  let u = localStorage.getItem('fpins_reviewer');
  if (!u) {
    try { u = (window.prompt('Your name (saved for pricing records):') || '').trim().slice(0, 30); }
    catch(e) { u = ''; }
    if (u) localStorage.setItem('fpins_reviewer', u);
    else u = 'unknown';
  }
  return u;
}
function _fbToast(msg, color) {
  let t = document.getElementById('_fb_toast');
  if (!t) {
    t = document.createElement('div');
    t.id = '_fb_toast';
    t.style.cssText = 'position:fixed;bottom:60px;left:50%;transform:translateX(-50%);'
      + 'padding:6px 14px;border-radius:20px;font-size:13px;font-weight:600;'
      + 'z-index:99999;pointer-events:none;transition:opacity .4s;opacity:0;white-space:nowrap';
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.style.background = color;
  t.style.color = '#fff';
  t.style.opacity = '1';
  clearTimeout(t._hide);
  t._hide = setTimeout(() => { t.style.opacity = '0'; }, 2000);
}
function _fbWrite(pk, fields) {
  const url = _DB_BASE + '/' + _rtdbPath(pk) + '.json';
  const body = JSON.stringify(Object.assign({ pin_key: pk }, fields, { reviewed_by: _getUser() }));
  return fetch(url, { method: 'PATCH', body, headers: { 'Content-Type': 'application/json' } })
    .then(r => {
      if (!r.ok) {
        _fbToast('⚠ Save failed (' + r.status + ')', '#8b0000');
        console.warn('Firebase write HTTP', r.status);
        throw new Error('HTTP ' + r.status);
      }
      return r;
    })
    .catch(e => {
      if (!(e && e.message && String(e.message).startsWith('HTTP '))) {
        _fbToast('⚠ Save failed — check network', '#8b0000');
        console.warn('Firebase write failed', e);
      }
      throw e;
    });
}
async function _fbReadAllPins() {
  const url = _DB_BASE + '/pin_pricing_tests/' + TEST_RUN_ID + '/' + APPROACH_ID + '/pins.json';
  try {
    const resp = await fetch(url);
    if (!resp.ok) { console.warn('Firebase read HTTP ' + resp.status); return {}; }
    return (await resp.json()) || {};
  } catch(e) { console.warn('Firebase read failed', e); return {}; }
}
</script>'''

# All page links used by the hamburger menu
_NAV_LINKS = [
    ('new_ctm.html',          'ClickToMatch v2'),
    ('nts_review.html',       'Slot Review'),
    ('new_ctp.html',          'ClickToPrice v2'),
    ('contact_sheet.html',    'Contact Sheet'),
    ('index.html',            'Overlay'),
]

def _hamburger_html(current: str) -> str:
    parts = []
    for href, label in _NAV_LINKS:
        cls = ' class="current"' if href == current else ''
        parts.append(f'  <a href="{href}"{cls}>{label}</a>')
    links = '\n'.join(parts)
    return f'<div id="nav-menu">\n{links}\n</div>\n'

_COMMON_CSS = '''\
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{font-family:-apple-system,sans-serif;background:#111;color:#eee;overscroll-behavior:none}
#hdr{position:sticky;top:0;z-index:100;background:#1a1a1a;
  border-bottom:1px solid #333;padding-top:env(safe-area-inset-top,0px)}
.hdr-row{height:48px;display:flex;align-items:center;padding:0 12px;gap:8px}
.hdr-title{font-size:16px;font-weight:600;flex:1}
.hdr-sub{font-size:13px;color:#888}
a.back-btn{color:#4a9eff;font-size:14px;text-decoration:none;padding:4px 0}
/* Hamburger */
#ham-btn{background:none;border:none;color:#eee;font-size:22px;
  padding:6px 4px;cursor:pointer;line-height:1;margin-left:4px}
#nav-menu{display:none;position:fixed;top:0;left:0;right:0;bottom:0;z-index:9999;
  background:rgba(0,0,0,.82);-webkit-transform:translateZ(0);transform:translateZ(0)}
#nav-menu.open{display:flex;flex-direction:column}
#nav-menu a{display:block;background:#222;border-bottom:1px solid #2a2a2a;
  padding:18px 22px;color:#eee;text-decoration:none;font-size:17px}
#nav-menu a.current{color:#4a9eff;font-weight:600}
#nav-menu a:active{background:#333}
'''

_HAMBURGER_JS = '''\
document.getElementById('ham-btn').addEventListener('click', function(e){
  e.stopPropagation();
  document.getElementById('nav-menu').classList.toggle('open');
});
document.getElementById('nav-menu').addEventListener('click', function(e){
  if (e.target === this) this.classList.remove('open');
});
'''

def _head(title: str, extra_css: str = '') -> str:
    return (
        '<!DOCTYPE html>\n<html lang="en"><head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        f'<title>{title}</title>\n'
        f'<style>\n{_COMMON_CSS}{extra_css}</style>\n'
        '</head><body>\n'
    )


# ══════════════════════════════════════════════════════════════════════════
# 1. CONTACT SHEET
# ══════════════════════════════════════════════════════════════════════════
def _gen_contact_sheet(pins, ctx, out_dir):
    sorted_pins = sorted(pins, key=lambda p: p['price'], reverse=True)
    records = [{'pk': p['pk'], 'crop': p['crop'], 'b64': p.get('crop_b64',''),
                'price': p['price'], 'title': p['title'], 'cats': p['cats'],
                'ms': p['ms'], 'thumb': p['thumb']} for p in sorted_pins]

    data_js = (
        "const PINS     = " + json.dumps(records, ensure_ascii=False) + ";\n"
        "const FB_CFG   = " + json.dumps(ctx['fb'],  ensure_ascii=False) + ";\n"
        "const TEST_RUN_ID = " + json.dumps(ctx['tri']) + ";\n"
        "const APPROACH_ID = " + json.dumps(ctx['api']) + ";\n"
        "const RUN_NAME    = " + json.dumps(ctx['rn'])  + ";\n"
    )

    extra_css = '''
.filter-bar{display:flex;gap:5px;padding:6px 10px;overflow-x:auto;
  -webkit-overflow-scrolling:touch;scrollbar-width:none}
.filter-bar::-webkit-scrollbar{display:none}
.fb{flex-shrink:0;padding:5px 10px;border-radius:14px;font-size:12px;
  border:1px solid #3a3a3a;background:#222;color:#888;cursor:pointer}
.fb.active{background:#1e4fa0;color:#fff;border-color:#2a5298}
#hdr-count{font-size:12px;color:#888;margin-right:4px}
/* Summary boxes */
#summary-row{display:flex;gap:6px;padding:6px 10px 4px}
.sum-box{flex:1;background:#1a1a1a;border-radius:8px;padding:7px 8px;
  border:1px solid #2a2a2a}
.sum-vals{display:flex;gap:10px;justify-content:space-around}
.sv{display:flex;flex-direction:column;align-items:center}
.sv-n{font-size:17px;font-weight:700;line-height:1}
.sv-l{font-size:10px;color:#888;margin-top:2px}
#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(105px,1fr));
  gap:2px;padding:2px;padding-bottom:env(safe-area-inset-bottom,20px)}
.card{position:relative;background:#1a1a1a;border-radius:4px;
  overflow:hidden;aspect-ratio:1;border:2px solid transparent}
.card.ms-match{border-color:#2a7a2a}
.card.ms-no_match{border-color:#666}
.card.ms-nomatch-needs-ctp{border-color:#e33}
.card.ms-nomatch-needs-ctp::after{content:'\\2715';position:absolute;top:2px;right:3px;color:#e33;font-size:10px;font-weight:bold;line-height:1;pointer-events:none;background:rgba(0,0,0,.65);border-radius:2px;padding:0 2px}
.card.ms-priced{border-color:#1a4a7a}
.card.ms-unreviewed{border-color:#333}
.card img{width:100%;height:100%;object-fit:contain;background:#222}
.price{position:absolute;top:3px;right:3px;background:rgba(0,0,0,.8);
  color:#fff;font-size:11px;font-weight:700;padding:2px 4px;border-radius:3px}
'''

    html = (
        _head('Contact Sheet · ' + ctx['rn'], extra_css)
        + '<div id="hdr">\n'
        + '  <div class="hdr-row">\n'
        + '    <div class="hdr-title">Contact Sheet</div>\n'
        + '    <div id="hdr-count"></div>\n'
        + '    <button id="ham-btn">&#9776;</button>\n'
        + '  </div>\n'
        + '  <div id="summary-row">\n'
        + '    <div class="sum-box"><div class="sum-vals">\n'
        + '      <div class="sv"><span class="sv-n" id="cnt-auto">—</span><span class="sv-l">Auto</span></div>\n'
        + '      <div class="sv"><span class="sv-n" id="cnt-match">—</span><span class="sv-l">Match</span></div>\n'
        + '      <div class="sv"><span class="sv-n" id="cnt-nomatch">—</span><span class="sv-l">No Match</span></div>\n'
        + '    </div></div>\n'
        + '    <div class="sum-box"><div class="sum-vals">\n'
        + '      <div class="sv"><span class="sv-n" id="cnt-notpin">—</span><span class="sv-l">Not a Pin</span></div>\n'
        + '      <div class="sv"><span class="sv-n" id="cnt-unreviewed">—</span><span class="sv-l">Unreviewed</span></div>\n'
        + '      <div class="sv"><span class="sv-n" id="cnt-total">—</span><span class="sv-l">Total</span></div>\n'
        + '    </div></div>\n'
        + '  </div>\n'
        + '  <div class="filter-bar">\n'
        + '    <button class="fb active" data-f="">All Pins</button>\n'
        + '    <button class="fb" data-f="nomatch_needs_ctp">No Match — no listing</button>\n'
        + '    <button class="fb" data-f="all_detections">All Detections</button>\n'
        + '    <button class="fb" data-f="hidden">Hidden Disney</button>\n'
        + '    <button class="fb" data-f="wdi">WDI</button>\n'
        + '    <button class="fb" data-f="dec">DEC</button>\n'
        + '    <button class="fb" data-f="dssh">DSSH</button>\n'
        + '    <button class="fb" data-f="le">LE</button>\n'
        + '    <button class="fb" data-f="premium">WDI+DEC+DSSH+LE</button>\n'
        + '  </div>\n'
        + '</div>\n'
        + _hamburger_html('contact_sheet.html')
        + '<div id="grid"></div>\n'
        + '<script>\n' + data_js + '''
const grid = document.getElementById('grid');
const countEl = document.getElementById('hdr-count');
let cards = [];

function pinNeedsCtpListingFromFb(fbPin) {
  if (!fbPin || fbPin.match_status !== 'no_match') return false;
  if (fbPin.selected_candidate_idx != null) return false;
  if (fbPin.selected_candidate) return false;
  return true;
}

PINS.forEach(p => {
  const card = document.createElement('div');
  const msClass = ['match','no_match','auto_match'].includes(p.ms)
    ? (p.ms === 'no_match' ? 'ms-no_match' : 'ms-match')
    : 'ms-unreviewed';
  const needsCtp = p.ms === 'no_match';
  card.className = 'card ' + msClass + (needsCtp ? ' ms-nomatch-needs-ctp' : '');
  card.dataset.cats = (p.cats || []).join(' ');
  card.dataset.ms = p.ms || 'unreviewed';
  card.dataset.needsCtp = needsCtp ? '1' : '0';
  const img = document.createElement('img');
  img.loading = 'lazy';
  img.src = p.b64 || ('../crops/' + encodeURIComponent(p.crop));
  img.alt = p.title;
  if (!p.b64) img.onerror = function(){ if(p.thumb){this.src=p.thumb;} this.onerror=null; };
  const pr = document.createElement('div');
  pr.className = 'price';
  pr.textContent = '$' + (p.price > 0 ? Math.round(p.price) : '?');
  card.append(img, pr);
  card.dataset.pk = p.pk;
  card.addEventListener('click', () => {
    window.location.href = 'new_ctp.html?pin=' + encodeURIComponent(p.pk);
  });
  grid.appendChild(card);
  cards.push(card);
});

function applyFilter(f) {
  let shown = 0;
  cards.forEach((c) => {
    const cats = c.dataset.cats || '';
    let show;
    if (!f) show = (c.dataset.ms || '') !== 'not_a_pin';
    else if (f === 'all_detections') show = true;
    else if (f === 'nomatch_needs_ctp') show = c.dataset.needsCtp === '1';
    else if (f === 'premium') show = ['wdi','dec','dssh','le'].some(x => cats.includes(x));
    else show = cats.includes(f);
    c.style.display = show ? '' : 'none';
    if (show) shown++;
  });
  countEl.textContent = shown + ' pins';
}
document.querySelectorAll('.fb').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.fb').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    applyFilter(btn.dataset.f);
  });
});
applyFilter('');
'''
        + '\n</script>\n'
        + '<script>\n' + _HAMBURGER_JS + '</script>\n'
        + _FB_SDK
        + '''
<script>
// Set total immediately from embedded data
(function() {
  const el = document.getElementById('cnt-total');
  if (el) el.textContent = PINS.length;
})();

// Hydrate prices + match status from Firebase REST API, then re-sort by confirmed price
(async function hydrateContactSheet() {
  const fbPins = await _fbReadAllPins();
  const keys = Object.keys(fbPins);
  if (!keys.length) { console.log('Contact sheet: no Firebase data for this run'); return; }
  const priceMap = {}, msMap = {}, needsCtpMap = {};
  for (const fbPin of Object.values(fbPins)) {
    const pk = fbPin.pin_key;
    if (!pk) continue;
    if (fbPin.display_price != null) priceMap[pk] = fbPin.display_price;
    if (fbPin.match_status)          msMap[pk]    = fbPin.match_status;
    needsCtpMap[pk] = pinNeedsCtpListingFromFb(fbPin);
  }
  // Update summary counts
  const counts = {auto_match:0, match:0, no_match:0, not_a_pin:0, priced:0};
  for (const ms of Object.values(msMap)) { if (counts.hasOwnProperty(ms)) counts[ms]++; }
  const unreviewed = PINS.length - Object.keys(msMap).length;
  const setN = (id, v) => { const e = document.getElementById(id); if(e) e.textContent = v; };
  setN('cnt-auto',       counts.auto_match);
  setN('cnt-match',      counts.match);
  setN('cnt-nomatch',    counts.no_match);
  setN('cnt-notpin',     counts.not_a_pin);
  setN('cnt-unreviewed', Math.max(0, unreviewed));
  // Update cards + track confirmed prices for re-sort
  let updated = 0;
  document.querySelectorAll('.card[data-pk]').forEach(card => {
    const pk = card.dataset.pk;
    if (priceMap[pk] != null) {
      const pr = card.querySelector('.price');
      if (pr) {
        const v = priceMap[pk];
        pr.textContent = '$' + (v > 0 ? Math.round(v) : '0');
        pr.style.background = v > 0 ? 'rgba(0,0,0,.8)' : 'rgba(100,0,0,.85)';
        card.dataset.sortPrice = v;
      }
      updated++;
    }
    if (msMap[pk]) {
      const ms = msMap[pk];
      card.dataset.ms = ms;
      const cls = ms === 'no_match' ? 'ms-no_match' : ms === 'priced' ? 'ms-priced'
                : ['match','auto_match'].includes(ms) ? 'ms-match' : 'ms-unreviewed';
      card.className = card.className.replace(/\bms-\S+/, cls);
    }
    if (Object.prototype.hasOwnProperty.call(needsCtpMap, pk)) {
      const needsCtp = !!needsCtpMap[pk];
      card.dataset.needsCtp = needsCtp ? '1' : '0';
      card.classList.toggle('ms-nomatch-needs-ctp', needsCtp);
    }
  });
  // Re-sort grid by confirmed price descending
  const allCards = [...document.querySelectorAll('.card[data-pk]')];
  allCards.sort((a, b) => {
    const pa = parseFloat(a.dataset.sortPrice ?? a.querySelector('.price')?.textContent?.replace(/[^0-9.]/g,'') ?? 0);
    const pb = parseFloat(b.dataset.sortPrice ?? b.querySelector('.price')?.textContent?.replace(/[^0-9.]/g,'') ?? 0);
    return pb - pa;
  });
  const g = document.getElementById('grid');
  allCards.forEach(c => g.appendChild(c));
  cards = allCards;  // keep cards array in sync for filter
  applyFilter(document.querySelector('.fb.active')?.dataset.f ?? '');
  console.log('Contact sheet: hydrated ' + updated + ' pins from Firebase, re-sorted by price');
})();
</script>
'''
        + '\n</body></html>'
    )

    out = out_dir / 'contact_sheet.html'
    out.write_text(html, encoding='utf-8')
    print(f'  contact_sheet.html ({len(sorted_pins)} pins)')


# ══════════════════════════════════════════════════════════════════════════
# 2. NEW CTM
# ══════════════════════════════════════════════════════════════════════════
def _gen_new_ctm(pins, ctx, out_dir):
    SKIP_STATUS = {'match', 'no_match', 'auto_match', 'not_a_pin'}
    # Unreviewed first; within queue sort by DINOv2 confidence (high → low).
    unrev = [p for p in pins if p['ms'] not in SKIP_STATUS]
    unrev.sort(key=lambda p: (p.get('best_sim') is None, -(p.get('best_sim') or 0)))
    records = [{'pk': p['pk'], 'crop': p['crop'], 'b64': p.get('crop_b64',''),
                'price': p['price'], 'thumb': p['thumb'], 'ms': p['ms'],
                'best_sim': p.get('best_sim'), 'tier': p.get('confidence_tier'),
                'show_slot': p.get('show_slot', 0)} for p in unrev]

    data_js = (
        "const PINS     = " + json.dumps(records, ensure_ascii=False) + ";\n"
        "const FB_CFG   = " + json.dumps(ctx['fb'],  ensure_ascii=False) + ";\n"
        "const TEST_RUN_ID = " + json.dumps(ctx['tri']) + ";\n"
        "const APPROACH_ID = " + json.dumps(ctx['api']) + ";\n"
        "const RUN_NAME    = " + json.dumps(ctx['rn'])  + ";\n"
        "const SKIP_MS  = " + json.dumps(list(SKIP_STATUS)) + ";\n"
    )

    extra_css = '''
body{height:100dvh;display:flex;flex-direction:column;overflow:hidden;
  padding-bottom:env(safe-area-inset-bottom,0px)}
#progress{font-size:12px;color:#888}
#done-banner{display:none;position:fixed;inset:0;background:#111;z-index:200;
  flex-direction:column;align-items:center;justify-content:center;
  font-size:20px;font-weight:700;gap:16px}
#done-banner.show{display:flex}
#done-banner a{color:#4a9eff;font-size:15px}
/* Photos fill remaining space above button zone — Our Pin LEFT, eBay RIGHT */
#photos{flex:1;display:flex;flex-direction:row;overflow:hidden;min-height:0}
#crop-wrap{flex:1;background:#1a1a1a;display:flex;align-items:center;
  justify-content:center;border-right:2px solid #333;overflow:hidden;position:relative}
#crop-img{width:100%;height:100%;object-fit:contain}
#crop-label{position:absolute;top:8px;left:8px;font-size:11px;color:#888;
  background:rgba(0,0,0,.6);padding:2px 6px;border-radius:4px}
#thumb-wrap{flex:1;background:#0e1a0e;display:flex;align-items:center;
  justify-content:center;overflow:hidden;position:relative}
#thumb-img{width:100%;height:100%;object-fit:contain}
#price-badge{position:absolute;bottom:8px;left:8px;font-size:14px;font-weight:700;
  color:#fff;background:rgba(0,0,0,.75);padding:3px 8px;border-radius:5px}
/* Swipe hint overlay (inside crop-wrap, left panel) */
#swipe-hint{position:absolute;inset:0;display:flex;pointer-events:none;
  align-items:center;justify-content:space-between;padding:0 12px;opacity:0;
  transition:opacity .15s}
#swipe-hint.show{opacity:1}
.sh-l{color:#ff6e6e;font-size:32px;font-weight:900}
.sh-r{color:#6eff6e;font-size:32px;font-weight:900}
/* Button zone — below photos, 3-column layout:
   left col:   Back (1x) / No Match (2x)   ← left thumb
   center:     Not a Pin (full 3x height)   ← either thumb
   right col:  Skip (1x) / Match (2x)       ← right thumb  */
#btn-area{display:flex;height:180px;flex-shrink:0}
#btn-col-left,#btn-col-right{flex:1;display:flex;flex-direction:column}
.rail-btn{flex:1;border:none;font-size:14px;font-weight:700;cursor:pointer;
  display:flex;align-items:center;justify-content:center;text-align:center;
  line-height:1.2;padding:0 6px;-webkit-tap-highlight-color:transparent;
  touch-action:manipulation}
#btn-match  {background:#1a6b1a;color:#6eff6e;flex:2}
#btn-nomatch{background:#6b1a1a;color:#ff6e6e;flex:2}
#btn-notpin {background:#5a3a00;color:#ffb84d;width:80px;flex-shrink:0}
#btn-back   {background:#1a1a3a;color:#8888ff;flex:1}
#btn-skip   {background:#2a2a2a;color:#aaa;flex:1}
#prog-wrap{height:4px;background:#2a2a2a;flex-shrink:0}
#prog-fill{height:100%;background:#2a6eff;transition:width .25s;width:0%}
#conf-badge{position:absolute;top:8px;right:8px;font-size:11px;font-weight:600;
  padding:2px 7px;border-radius:4px;background:rgba(0,0,0,.65)}
#conf-badge.high{color:#6eff6e}
#conf-badge.medium{color:#ffdd57}
#conf-badge.low{color:#ff9999}
'''

    html = (
        _head('ClickToMatch · ' + ctx['rn'], extra_css)
        + '<div id="hdr">\n'
        + '  <div class="hdr-row">\n'
        + '    <div class="hdr-title">ClickToMatch</div>\n'
        + '    <div id="progress"></div>\n'
        + '    <button id="ham-btn">&#9776;</button>\n'
        + '  </div>\n'
        + '</div>\n'
        + _hamburger_html('new_ctm.html')
        + '<div id="prog-wrap"><div id="prog-fill"></div></div>\n'
        + '''
<div id="photos">
  <div id="crop-wrap">
    <img id="crop-img" alt="Pin crop">
    <div id="crop-label">Our Pin</div>
    <div id="swipe-hint"><span class="sh-l">✗</span><span class="sh-r">✓</span></div>
  </div>
  <div id="thumb-wrap">
    <img id="thumb-img" alt="eBay listing">
    <div id="price-badge"></div>
    <div id="conf-badge"></div>
  </div>
</div>

<div id="btn-area">
  <div id="btn-col-left">
    <button class="rail-btn" id="btn-back">Back</button>
    <button class="rail-btn" id="btn-nomatch">No Match</button>
  </div>
  <button class="rail-btn" id="btn-notpin">Not a<br>Pin</button>
  <div id="btn-col-right">
    <button class="rail-btn" id="btn-skip">Skip</button>
    <button class="rail-btn" id="btn-match">Match ✓</button>
  </div>
</div>

<div id="done-banner">
  <div>✓ ClickToMatch complete!</div>
  <a href="new_ctp.html?filter=no_match">Continue to ClickToPrice (no match)</a>
  <a href="contact_sheet.html" style="font-size:14px;margin-top:8px">Contact Sheet</a>
</div>

<script>
''' + data_js + '''
const STORE_KEY = 'ctm_idx_' + RUN_NAME;
const queue = PINS.filter(p => !SKIP_MS.includes(p.ms));
let idx = parseInt(sessionStorage.getItem(STORE_KEY) || '0', 10);
if (idx >= queue.length) idx = 0;
let history = [];

const cropEl   = document.getElementById('crop-img');
const thumbEl  = document.getElementById('thumb-img');
const badgeEl  = document.getElementById('price-badge');
const progEl   = document.getElementById('progress');
const hintEl   = document.getElementById('swipe-hint');
const confEl   = document.getElementById('conf-badge');

''' + f"const GRAY = '{_GRAY_PLACEHOLDER}';\n" + '''
function showPin(i) {
  sessionStorage.setItem(STORE_KEY, i);
  if (i >= queue.length) { document.getElementById('done-banner').classList.add('show'); return; }
  const p = queue[i];
  cropEl.src = p.b64 || ('../crops/' + encodeURIComponent(p.crop));
  if (!p.b64) cropEl.onerror = function(){ this.src=GRAY; this.onerror=null; };
  thumbEl.src = p.thumb || '';
  badgeEl.textContent = p.price > 0 ? '$' + Math.round(p.price) : '';
  if (confEl) {
    const t = p.tier || 'unknown';
    confEl.className = t;
    confEl.textContent = p.best_sim != null
      ? (t.charAt(0).toUpperCase() + t.slice(1) + ' ' + p.best_sim.toFixed(2))
      : '';
  }
  progEl.textContent = (i+1) + ' / ' + queue.length;
  const _pct = queue.length > 0 ? Math.round(Math.min(i, queue.length) / queue.length * 100) : 100;
  const _fill = document.getElementById('prog-fill');
  if (_fill) { _fill.style.width = _pct+'%'; _fill.style.background = _pct===100 ? '#1a5e1a' : '#2a6eff'; }
}

function record(pk, status) {
  return _fbWrite(pk, { match_status: status, matched_at: new Date().toISOString() });
}

function doAction(status) {
  if (idx >= queue.length) return;
  const p = queue[idx];
  history.push(idx);
  idx++;
  showPin(idx);
  try { record(p.pk, status); } catch(e) { console.warn('CTM write failed', e); }
}

document.getElementById('btn-match').addEventListener('click', () => doAction('match'));
document.getElementById('btn-nomatch').addEventListener('click', () => doAction('no_match'));

document.getElementById('btn-notpin').addEventListener('click', () => {
  if (idx >= queue.length) return;
  const p = queue[idx];
  history.push(idx);
  idx++;
  showPin(idx);
  try {
    _fbWrite(p.pk, {
      match_status: 'not_a_pin',
      display_price: 0,
      marked_not_a_pin_at: new Date().toISOString(),
    });
  } catch(e) { console.warn('not-a-pin write failed', e); }
});

document.getElementById('btn-skip').addEventListener('click', () => {
  if (idx >= queue.length) return;
  history.push(idx); idx++; showPin(idx);
});

document.getElementById('btn-back').addEventListener('click', () => {
  if (history.length === 0) return;
  idx = history.pop(); showPin(idx);
});

// ── Swipe gestures ────────────────────────────────────────────────────────
let touchX0 = null, touchY0 = null;
const photos = document.getElementById('photos');

photos.addEventListener('touchstart', e => {
  touchX0 = e.touches[0].clientX;
  touchY0 = e.touches[0].clientY;
}, {passive:true});

photos.addEventListener('touchmove', e => {
  if (touchX0 === null) return;
  const dx = e.touches[0].clientX - touchX0;
  const dy = e.touches[0].clientY - touchY0;
  if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 20) {
    hintEl.className = dx > 0 ? 'show' : 'show';
    hintEl.style.justifyContent = dx > 0 ? 'flex-end' : 'flex-start';
  }
}, {passive:true});

photos.addEventListener('touchend', e => {
  if (touchX0 === null) return;
  const dx = e.changedTouches[0].clientX - touchX0;
  const dy = e.changedTouches[0].clientY - touchY0;
  hintEl.className = '';
  touchX0 = null; touchY0 = null;
  if (Math.abs(dx) < Math.abs(dy) || Math.abs(dx) < 60) return;
  if (dx > 0) doAction('match');
  else doAction('no_match');
});

showPin(idx);
</script>
'''
        + '<script>\n' + _HAMBURGER_JS + '</script>\n'
        + _FB_SDK
        + '''
<script>
// Hydrate from RTDB: remove already-reviewed pins from queue.
// All pin data (auto-match + CTM v2 reviews) lives in RTDB.
(async function hydrateFromFirebase() {
  const SKIP    = new Set(SKIP_MS);
  const fbPins  = await _fbReadAllPins();
  let removed   = 0;
  for (const fbPin of Object.values(fbPins)) {
    const ms = fbPin.match_status;
    const pk = fbPin.pin_key;
    if (ms && pk && SKIP.has(ms)) {
      const qi = queue.findIndex(p => p.pk === pk);
      if (qi !== -1) { queue.splice(qi, 1); removed++; }
    }
  }
  if (removed > 0) {
    console.log('CTM hydrated: removed ' + removed + ' reviewed pins');
    idx = 0; history = [];
    sessionStorage.setItem(STORE_KEY, 0);
    showPin(0);
  }
})();
</script>
'''
        + '\n</body></html>'
    )

    out = out_dir / 'new_ctm.html'
    out.write_text(html, encoding='utf-8')
    unrev = len([p for p in pins if p['ms'] not in SKIP_STATUS])
    print(f'  new_ctm.html ({len(records)} in queue, {unrev} unreviewed, confidence-sorted)')


# ══════════════════════════════════════════════════════════════════════════
# 3. NTS REVIEW WHEEL (Slot Review — matched pins at slot > 0 only)
# ══════════════════════════════════════════════════════════════════════════
_SLOT_REVIEW_MATCH = {'match', 'auto_match'}


def _fb_pins_by_key(fb_pins: dict) -> dict:
    """Normalize Firebase export pins dict to pin_key → entry."""
    out = {}
    for entry in (fb_pins or {}).values():
        pk = entry.get('pin_key')
        if pk:
            out[pk] = entry
    return out


def _matched_slot_idx(pin: dict, fb_entry: dict | None = None) -> int | None:
    """Return chosen slot for a matched pin, or None if not in the review queue."""
    fb_entry = fb_entry or {}
    ms = fb_entry.get('match_status') or pin.get('ms') or 'unreviewed'
    if ms not in _SLOT_REVIEW_MATCH:
        return None
    idx = fb_entry.get('selected_candidate_idx')
    if idx is not None:
        idx = int(idx)
        return idx if idx > 0 else None
    # Firebase match without index = slot-0 swipe in CTM — not a slot-review case.
    if fb_entry and ms in _SLOT_REVIEW_MATCH:
        return None
    # No Firebase row yet — fall back to displayed slot for in-progress runs.
    for key in ('show_slot', 'best_slot', 'auto_slot'):
        v = pin.get(key)
        if v is not None:
            v = int(v)
            return v if v > 0 else None
    return None


def _slot_review_queue(pins: list, fb_pins_by_pk: dict | None = None) -> list:
    """Pins where user matched (or auto-matched) a candidate above slot 0."""
    fb_pins_by_pk = fb_pins_by_pk or {}
    nts = []
    for p in pins:
        slot = _matched_slot_idx(p, fb_pins_by_pk.get(p['pk']))
        if slot is not None and slot > 0:
            p = dict(p)
            p['matched_slot'] = slot
            nts.append(p)
    nts.sort(key=lambda p: (
        p.get('var', 0),
        p.get('matched_slot', 0),
    ), reverse=True)
    return nts


def _gen_nts_review(pins, ctx, out_dir, fb_pins_by_pk=None):
    nts = _slot_review_queue(pins, fb_pins_by_pk)

    records = [{
        'pk':       p['pk'],
        'crop':     p['crop'],
        'b64':      p.get('crop_b64',''),
        'price':    p['price'],
        'title':    p['title'][:60],
        'thumb':    p['thumb'],
        'slot0_p':  p['slot0_p'],
        'cheapest': p['cheapest'],
        'var':      p['var'],
        'auto_slot': p.get('matched_slot', p.get('auto_slot')),
        'auto_sim':  p.get('auto_sim'),
        'cands':    p['cands'],
    } for p in nts]

    data_js = (
        "const PINS     = " + json.dumps(records, ensure_ascii=False) + ";\n"
        "const FB_CFG   = " + json.dumps(ctx['fb'],  ensure_ascii=False) + ";\n"
        "const TEST_RUN_ID = " + json.dumps(ctx['tri']) + ";\n"
        "const APPROACH_ID = " + json.dumps(ctx['api']) + ";\n"
        "const RUN_NAME    = " + json.dumps(ctx['rn'])  + ";\n"
    )

    extra_css = '''
/* ── Layout ── */
body{height:100dvh;display:flex;flex-direction:column;overflow:hidden}
/* ── Compact pin meta row (in header) ── */
#pin-meta{display:flex;align-items:center;gap:8px;padding:3px 10px 5px;
  background:#111;border-bottom:1px solid #222;flex-shrink:0}
.pm-title{flex:1;font-size:11px;color:#bbb;overflow:hidden;
  white-space:nowrap;text-overflow:ellipsis}
.pm-right{display:flex;align-items:center;gap:8px;flex-shrink:0}
.pm-idx{font-size:10px;color:#555;white-space:nowrap}
.pd-undo{font-size:11px;color:#4a9eff;background:none;border:none;
  cursor:pointer;padding:0;display:none;text-decoration:underline}
/* ── Tile grid ── */
#tile-area{flex:1;overflow-y:auto;min-height:0;padding:6px;
  -webkit-overflow-scrolling:touch}
#tile-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
.tile{position:relative;border-radius:6px;overflow:hidden;
  background:#1a1a1a;border:2px solid transparent;cursor:pointer;
  display:flex;flex-direction:column}
.tile img{width:100%;aspect-ratio:1;object-fit:contain;background:#1a1a1a;flex-shrink:0}
.tile-pbar{background:rgba(0,0,0,.9);padding:3px 5px;
  display:flex;justify-content:space-between;align-items:center;flex-shrink:0}
.tile-price{font-size:11px;font-weight:700;color:#fff}
.tile-delta{font-size:10px;color:#6eff6e}
.tile-delta.worse{color:#ff6e6e}.tile-delta.same{color:#888}
.tile-sn{position:absolute;top:3px;left:3px;background:rgba(0,0,0,.65);
  color:#888;font-size:9px;padding:1px 3px;border-radius:2px;z-index:1}
.tile.chosen{border-color:#f0c040}
.tile.chosen .tile-sn{background:rgba(240,192,64,.85);color:#000;font-weight:700}
.tile.not-a-pin{border-color:#555;opacity:.5}
.tile-star{position:absolute;top:3px;right:3px;font-size:13px;line-height:1;z-index:1}
.tile-chk{position:absolute;bottom:24px;right:4px;color:#6eff6e;
  font-size:13px;display:none;z-index:1}
.tile.confirmed-sel .tile-chk{display:block}
/* ── My Pin tile ── */
.pin-tile{border:2px solid #1a3a1a;border-left:4px solid #6eff6e;cursor:default}
.pin-tile .tile-sn{background:rgba(60,180,60,.85);color:#000;font-weight:700}
.tile-mypin{position:absolute;bottom:24px;left:3px;
  background:rgba(20,70,20,.9);color:#6eff6e;font-size:9px;font-weight:700;
  padding:1px 4px;border-radius:2px;z-index:1}
/* ── History (prior-run) candidate badge ── */
.tile.hist{border-color:#c07af0}
.tile-hist{position:absolute;top:3px;left:3px;
  background:rgba(150,60,220,.92);color:#fff;font-size:8px;font-weight:700;
  padding:1px 4px;border-radius:2px;z-index:2;line-height:1.3}
/* ── Bottom nav ── */
#bottom-nav{flex-shrink:0;background:#111;border-top:1px solid #222;padding:5px 8px 8px}
.var-bar{display:flex;gap:4px;overflow-x:auto;margin-bottom:5px;
  -webkit-overflow-scrolling:touch;scrollbar-width:none}
.var-bar::-webkit-scrollbar{display:none}
.vb{flex-shrink:0;padding:2px 7px;border-radius:10px;font-size:11px;
  border:1px solid #3a3a3a;background:#222;color:#888;cursor:pointer}
.vb.active{background:#1e4fa0;color:#fff;border-color:#2a5298}
.vb-lbl{flex-shrink:0;font-size:10px;color:#555;align-self:center;padding-right:2px}
.nav-row{display:flex;gap:6px}
.nav-btn{height:44px;border:none;border-radius:8px;font-size:15px;
  font-weight:700;cursor:pointer;transition:opacity .15s}
.nav-btn:disabled{opacity:.35;cursor:default}
#back-btn{flex:4;background:#2a2a2a;color:#aaa}
#nap-btn{flex:2;background:#3a1010;color:#cc4444;font-size:14px;border-radius:8px}
#next-btn{flex:4;background:#1e4fa0;color:#fff}
/* ── eBay search (below fold) ── */
#ebay-section{padding:10px 6px 20px;border-top:1px solid #222;margin-top:4px}
.ebay-lbl{font-size:10px;color:#555;margin-bottom:4px}
#ebay-form input{width:100%;box-sizing:border-box;padding:8px 10px;
  border-radius:6px;border:1px solid #333;background:#1a1a1a;
  color:#fff;font-size:14px}
/* ── Progress bar ── */
#prog-wrap{height:4px;background:#2a2a2a;flex-shrink:0}
#prog-fill{height:100%;background:#2a6eff;transition:width .25s;width:0%}
'''

    html = (
        _head('Slot Review · ' + ctx['rn'], extra_css)
        + '<div id="hdr">\n'
        + '  <div class="hdr-row">\n'
        + '    <div class="hdr-title">Slot Review</div>\n'
        + '    <div class="hdr-sub" id="nts-count"></div>\n'
        + '    <button id="ham-btn">&#9776;</button>\n'
        + '  </div>\n'
        + '  <div id="pin-meta">\n'
        + '    <div class="pm-title" id="pd-title">—</div>\n'
        + '    <div class="pm-right">\n'
        + '      <span class="pm-idx" id="pd-idx"></span>\n'
        + '      <button class="pd-undo" id="undo-btn">&#8617; Undo</button>\n'
        + '    </div>\n'
        + '  </div>\n'
        + '</div>\n'
        + _hamburger_html('nts_review.html')
        + '<div id="prog-wrap"><div id="prog-fill"></div></div>\n'
        + '''
<div id="tile-area">
  <div id="tile-grid"></div>
  <div id="ebay-section">
    <div class="ebay-lbl">eBay search</div>
    <form id="ebay-form">
      <input id="ebay-input" type="search" placeholder="Search eBay...">
    </form>
  </div>
</div>
<div id="bottom-nav">
  <div class="var-bar">
    <span class="vb-lbl">Save&#8805;:</span>
    <button class="vb active" data-var="0">All (<span id="v0-cnt">&#8230;</span>)</button>
    <button class="vb" data-var="5">&gt;$5 (<span id="v5-cnt">&#8230;</span>)</button>
    <button class="vb" data-var="10">&gt;$10 (<span id="v10-cnt">&#8230;</span>)</button>
    <button class="vb" data-var="15">&gt;$15 (<span id="v15-cnt">&#8230;</span>)</button>
    <button class="vb" data-var="20">&gt;$20 (<span id="v20-cnt">&#8230;</span>)</button>
  </div>
  <div class="nav-row">
    <button class="nav-btn" id="back-btn">&#8592; Back</button>
    <button class="nav-btn" id="nap-btn" title="Not a pin">&#10007;</button>
    <button class="nav-btn" id="next-btn">Next &#8594;</button>
  </div>
</div>
'''
        + _FB_SDK
        + '''
<script>
''' + data_js + f"const GRAY = '{_GRAY_PLACEHOLDER}';\n" + '''
const STORE_KEY = 'nts_v2_' + RUN_NAME;
document.getElementById('nts-count').textContent = PINS.length + ' pins';

let selPin = 0;
let confirmed = {};   // pk -> origIdx  (or -1 for not-a-pin)
let lastUndo  = null;
let varFilter = 0;
let displayPins = [...PINS];

function fmt(p) { return (p != null && !isNaN(p) && p >= 0) ? '$' + Math.round(p) : '$?'; }

function calcSavings(p) {
  const prices = (p.cands||[]).filter(c => c.p > 0).map(c => c.p);
  if (!prices.length) return 0;
  return Math.max(0, (p.price || p.slot0_p) - Math.min(...prices));
}

function updateVarCounts() {
  [0,5,10,15,20].forEach(t => {
    const cnt = PINS.filter(p => calcSavings(p) >= t).length;
    const el = document.getElementById('v'+t+'-cnt');
    if (el) el.textContent = cnt;
  });
}

function chosenIdx(p) {
  const c = confirmed[p.pk];
  if (c != null && c >= 0) return c;
  if (p.auto_slot != null && p.auto_slot > 0) return p.auto_slot;
  return 0;
}

function renderPin(pi) {
  const p = displayPins[pi]; if (!p) return;
  // Progress + nav
  document.getElementById('pd-idx').textContent = (pi+1) + ' / ' + displayPins.length;
  const _pct = displayPins.length > 1 ? Math.round(pi / (displayPins.length-1) * 100) : 100;
  const _fill = document.getElementById('prog-fill');
  if (_fill) { _fill.style.width = _pct+'%'; _fill.style.background = _pct===100 ? '#1a5e1a' : '#2a6eff'; }
  document.getElementById('back-btn').disabled = (pi === 0);
  const isLast = pi === displayPins.length - 1;
  const nextBtn = document.getElementById('next-btn');
  nextBtn.textContent = isLast ? 'Done ✓' : 'Next →';
  nextBtn.style.background = isLast ? '#1a5e1a' : '#1e4fa0';
  // Header meta row
  document.getElementById('pd-title').textContent = p.title || p.pk;
  document.getElementById('undo-btn').style.display =
    (lastUndo && lastUndo.pk === p.pk) ? 'inline' : 'none';
  // eBay prefill
  const ei = document.getElementById('ebay-input');
  if (ei && !ei.dataset.edited) ei.value = p.title || '';
  renderTiles(p);
  document.getElementById('tile-area').scrollTop = 0;
}

function renderTiles(p) {
  const grid = document.getElementById('tile-grid');
  grid.innerHTML = '';
  // Attach origIdx to every candidate (index in the cands array)
  const candsWithIdx = (p.cands||[]).map((c, i) => ({...c, origIdx: i}));
  const isNaP = confirmed[p.pk] === -1;
  const isConf = confirmed[p.pk] != null;
  const coi = chosenIdx(p);
  const chosenCand = candsWithIdx[coi] || candsWithIdx[0];
  const chosenPrice = isNaP ? 0 : (chosenCand ? (chosenCand.p || p.slot0_p) : p.slot0_p);
  const cheapest = Math.min(...candsWithIdx.filter(c => c.p > 0).map(c => c.p));
  const pinDelta = isNaP ? 0 : Math.max(0, chosenPrice - cheapest);

  // ── My Pin tile (first in grid) ──
  const pinTile = document.createElement('div');
  pinTile.className = 'tile pin-tile';
  const pinImg = document.createElement('img');
  pinImg.src = p.b64 || ('../crops/' + encodeURIComponent(p.crop));
  if (!p.b64) { pinImg.onerror = () => { pinImg.src = GRAY; pinImg.onerror = null; }; }
  const pinPbar = document.createElement('div');
  pinPbar.className = 'tile-pbar';
  const pinPr = document.createElement('span');
  pinPr.className = 'tile-price';
  pinPr.textContent = isNaP ? 'NaP' : fmt(chosenPrice);
  const pinDt = document.createElement('span');
  pinDt.className = 'tile-delta';
  pinDt.textContent = isNaP ? '✖' : (pinDelta >= 0.5 ? '−$'+Math.round(pinDelta) : '✓ best');
  pinPbar.append(pinPr, pinDt);
  const pinSn = document.createElement('div');
  pinSn.className = 'tile-sn';
  pinSn.textContent = (p.auto_slot != null && p.auto_slot !== 0) ? 'AUTO S'+p.auto_slot : 'S'+coi;
  const pinMypin = document.createElement('div');
  pinMypin.className = 'tile-mypin'; pinMypin.textContent = 'My pin';
  pinTile.append(pinImg, pinPbar, pinSn, pinMypin);
  grid.appendChild(pinTile);

  // ── eBay candidate tiles (ascending price) ──
  const sorted = candsWithIdx.slice().sort((a,b) => (a.p||0)-(b.p||0));
  sorted.forEach(c => {
    const isChosen = !isNaP && c.origIdx === coi;
    const dSav = Math.round(chosenPrice - (c.p||0));

    const tile = document.createElement('div');
    tile.className = 'tile'
      + (isChosen ? ' chosen' : '')
      + (isChosen && isConf ? ' confirmed-sel' : '')
      + (isNaP ? ' not-a-pin' : '');

    const img = document.createElement('img');
    img.src = c.thumb || '';
    img.loading = 'lazy';
    img.onerror = () => { img.style.display='none'; };

    const pbar = document.createElement('div');
    pbar.className = 'tile-pbar';
    const pr = document.createElement('span');
    pr.className = 'tile-price'; pr.textContent = fmt(c.p);
    const dt = document.createElement('span');
    if (isChosen) {
      dt.className = 'tile-delta same'; dt.textContent = 'chosen';
    } else if (dSav > 0) {
      dt.className = 'tile-delta'; dt.textContent = '−$'+dSav;
    } else if (dSav < 0) {
      dt.className = 'tile-delta worse'; dt.textContent = '+$'+Math.abs(dSav);
    } else {
      dt.className = 'tile-delta same'; dt.textContent = '=$';
    }
    pbar.append(pr, dt);

    const sn = document.createElement('div');
    sn.className = 'tile-sn'; sn.textContent = 'S'+c.origIdx;

    tile.append(img, pbar, sn);

    if (isChosen) {
      const star = document.createElement('div');
      star.className = 'tile-star'; star.textContent = '★';
      tile.appendChild(star);
    }
    if (isChosen && isConf) {
      const chk = document.createElement('div');
      chk.className = 'tile-chk'; chk.textContent = '✓';
      tile.appendChild(chk);
    }

    tile.addEventListener('click', () => selectAndAdvance(p, c.origIdx));
    grid.appendChild(tile);
  });
}

function selectAndAdvance(p, origIdx) {
  const prevOrigIdx = confirmed[p.pk];
  const prevPrice = p.price || p.slot0_p;
  confirmed[p.pk] = origIdx;
  const cand = (p.cands||[])[origIdx];   // direct index — origIdx IS the array position
  const newPrice = cand ? (cand.p||0) : 0;
  p.price = newPrice;
  lastUndo = { pk: p.pk, pinI: selPin, prevOrigIdx, prevPrice };
  _fbWrite(p.pk, {
    selected_candidate_idx: origIdx,
    display_price: newPrice,
    slot_reviewed_at: new Date().toISOString(),
    match_status: 'priced'
  });
  const prevSel = selPin;
  navigate(1);
  if (selPin === prevSel) renderPin(selPin); // last pin: re-render to show chosen state
}

function markNotAPin(p) {
  const prevOrigIdx = confirmed[p.pk];
  const prevPrice = p.price || p.slot0_p;
  confirmed[p.pk] = -1;
  p.price = 0;
  lastUndo = { pk: p.pk, pinI: selPin, prevOrigIdx, prevPrice };
  _fbWrite(p.pk, {
    display_price: 0,
    not_a_pin: true,
    slot_reviewed_at: new Date().toISOString(),
    match_status: 'not_a_pin'
  });
  navigate(1);
}

function navigate(dir) {
  const newPi = selPin + dir;
  if (newPi < 0 || newPi >= displayPins.length) return;
  if (dir !== 0) lastUndo = null;
  selPin = newPi;
  const ei = document.getElementById('ebay-input');
  if (ei) { ei.value = ''; delete ei.dataset.edited; }
  sessionStorage.setItem(STORE_KEY, selPin);
  renderPin(selPin);
}

document.getElementById('back-btn').addEventListener('click', () => {
  lastUndo = null;
  navigate(-1);
});
document.getElementById('next-btn').addEventListener('click', () => {
  const p = displayPins[selPin];
  // Confirm current slot if not already explicitly reviewed
  if (p && confirmed[p.pk] == null) {
    const coi = chosenIdx(p);
    const cand = (p.cands||[])[coi];
    const price = cand ? (cand.p || p.slot0_p) : p.slot0_p;
    confirmed[p.pk] = coi;
    p.price = price;
    _fbWrite(p.pk, {
      selected_candidate_idx: coi,
      display_price: price,
      slot_reviewed_at: new Date().toISOString(),
      match_status: 'priced'
    });
  }
  navigate(1);
});
document.getElementById('nap-btn').addEventListener('click', () => {
  const p = displayPins[selPin]; if (p) markNotAPin(p);
});

document.getElementById('undo-btn').addEventListener('click', () => {
  if (!lastUndo) return;
  const { pk, prevOrigIdx, prevPrice } = lastUndo;
  const p = displayPins[selPin];
  if (!p || p.pk !== pk) return;
  if (prevOrigIdx != null && prevOrigIdx >= 0) {
    confirmed[pk] = prevOrigIdx;
    const pc = (p.cands||[])[prevOrigIdx];   // direct index
    p.price = pc ? (pc.p||0) : prevPrice;
    _fbWrite(pk, { selected_candidate_idx: prevOrigIdx, display_price: p.price,
                   slot_reviewed_at: new Date().toISOString() });
  } else {
    delete confirmed[pk];
    p.price = prevPrice;
    _fbWrite(pk, { selected_candidate_idx: 0, display_price: prevPrice||0 });
  }
  lastUndo = null;
  renderPin(selPin);
});

document.querySelectorAll('.vb').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.vb').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    varFilter = parseInt(btn.dataset.var, 10);
    displayPins = varFilter > 0 ? PINS.filter(p => calcSavings(p) >= varFilter) : [...PINS];
    selPin = 0; lastUndo = null;
    sessionStorage.removeItem(STORE_KEY);
    renderPin(0);
  });
});

const ebayForm = document.getElementById('ebay-form');
if (ebayForm) {
  ebayForm.addEventListener('submit', e => {
    e.preventDefault();
    const q = document.getElementById('ebay-input').value.trim();
    if (q) window.open('https://www.ebay.com/sch/i.html?_nkw='+encodeURIComponent(q)+'&_sop=15', '_blank');
  });
  document.getElementById('ebay-input').addEventListener('input', e => {
    e.target.dataset.edited = '1';
  });
}

// Firebase hydration, then render
(async () => {
  try {
    const fbData = await _fbReadAllPins();
    Object.entries(fbData).forEach(([dk, entry]) => {
      if (!entry.slot_reviewed_at) return;
      const pk = entry.pin_key || '';
      const p = PINS.find(x => x.pk === pk);
      if (!p) return;
      if (entry.not_a_pin) {
        confirmed[p.pk] = -1; p.price = 0;
      } else if (entry.selected_candidate_idx != null) {
        confirmed[p.pk] = entry.selected_candidate_idx;
        if (entry.display_price) p.price = entry.display_price;
      }
    });
  } catch(e) { console.warn('Firebase hydration failed', e); }
  updateVarCounts();
  const saved = parseInt(sessionStorage.getItem(STORE_KEY)||'0', 10);
  selPin = Math.min(displayPins.length-1, Math.max(0, saved));
  renderPin(selPin);
})();
</script>
'''
        + '<script>\n' + _HAMBURGER_JS + '</script>\n'
        + '\n</body></html>'
    )

    out = out_dir / 'nts_review.html'
    out.write_text(html, encoding='utf-8')
    print(f'  nts_review.html ({len(nts)} pins)')


# ══════════════════════════════════════════════════════════════════════════
# 4. NEW CTP
# ══════════════════════════════════════════════════════════════════════════
def _gen_new_ctp(pins, ctx, out_dir):
    sorted_pins = sorted(pins, key=lambda p: p['price'], reverse=True)
    records = [{
        'pk':    p['pk'],
        'crop':  p['crop'],
        'board_num': p.get('board_num', ''),
        'pin_n': p.get('pin_n', 0),
        'b64':   p.get('crop_b64',''),
        'price': p['price'],
        'title': p['title'][:70],
        'thumb': p['thumb'],
        'cands': p['cands'],
        'cats':  p['cats'],
        'ms':    p['ms'],
        'show_slot': p.get('show_slot', 0),
    } for p in sorted_pins]

    data_js = (
        "const PINS     = " + json.dumps(records, ensure_ascii=False) + ";\n"
        "const FB_CFG   = " + json.dumps(ctx['fb'],  ensure_ascii=False) + ";\n"
        "const TEST_RUN_ID = " + json.dumps(ctx['tri']) + ";\n"
        "const APPROACH_ID = " + json.dumps(ctx['api']) + ";\n"
        "const RUN_NAME    = " + json.dumps(ctx['rn'])  + ";\n"
    )

    extra_css = '''
body{height:100dvh;display:flex;flex-direction:column;overflow:hidden}
/* ── Compact pin meta row (in header) ── */
#pin-meta{display:flex;align-items:center;gap:8px;padding:3px 10px 5px;
  background:#111;border-bottom:1px solid #222;flex-shrink:0}
.pm-title{flex:1;font-size:11px;color:#bbb;overflow:hidden;
  white-space:nowrap;text-overflow:ellipsis}
.pm-right{display:flex;align-items:center;gap:8px;flex-shrink:0}
.pm-idx{font-size:10px;color:#555;white-space:nowrap}
.pd-undo{font-size:11px;color:#4a9eff;background:none;border:none;
  cursor:pointer;padding:0;display:none;text-decoration:underline}
#src-back-btn{display:none;background:none;border:none;color:#4a9eff;
  font-size:22px;cursor:pointer;padding:0 4px 0 0;line-height:1;flex-shrink:0}
/* ── Filter bar ── */
.filter-bar{display:flex;gap:5px;padding:5px 10px;overflow-x:auto;
  -webkit-overflow-scrolling:touch;scrollbar-width:none;border-bottom:1px solid #222;
  flex-shrink:0}
.filter-bar::-webkit-scrollbar{display:none}
.fb{flex-shrink:0;padding:4px 9px;border-radius:14px;font-size:11px;
  border:1px solid #3a3a3a;background:#222;color:#888;cursor:pointer}
.fb.active{background:#1e4fa0;color:#fff;border-color:#2a5298}
.bar-label{flex-shrink:0;font-size:10px;color:#555;align-self:center;padding-right:2px}
/* ── Tile grid ── */
#tile-area{flex:1;overflow-y:auto;min-height:0;padding:6px;
  -webkit-overflow-scrolling:touch}
#tile-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
.tile{position:relative;border-radius:6px;overflow:hidden;
  background:#1a1a1a;border:2px solid transparent;cursor:pointer;
  display:flex;flex-direction:column}
.tile img{width:100%;aspect-ratio:1;object-fit:contain;background:#1a1a1a;flex-shrink:0}
.tile-pbar{background:rgba(0,0,0,.9);padding:3px 5px;
  display:flex;justify-content:space-between;align-items:center;flex-shrink:0}
.tile-price{font-size:11px;font-weight:700;color:#fff}
.tile-delta{font-size:10px;color:#6eff6e}
.tile-delta.worse{color:#ff6e6e}.tile-delta.same{color:#888}
.tile-sn{position:absolute;top:3px;left:3px;background:rgba(0,0,0,.65);
  color:#888;font-size:9px;padding:1px 3px;border-radius:2px;z-index:1}
.tile.chosen{border-color:#f0c040}
.tile.chosen .tile-sn{background:rgba(240,192,64,.85);color:#000;font-weight:700}
.tile.not-a-pin{border-color:#555;opacity:.5}
.tile-star{position:absolute;top:3px;right:3px;font-size:13px;line-height:1;z-index:1}
.tile-chk{position:absolute;bottom:24px;right:4px;color:#6eff6e;
  font-size:13px;display:none;z-index:1}
.tile.confirmed-sel .tile-chk{display:block}
/* ── My Pin tile ── */
.pin-tile{border:2px solid #1a3a1a;border-left:4px solid #6eff6e;cursor:default}
.pin-tile .tile-sn{background:rgba(60,180,60,.85);color:#000;font-weight:700}
.tile-mypin{position:absolute;bottom:24px;left:3px;
  background:rgba(20,70,20,.9);color:#6eff6e;font-size:9px;font-weight:700;
  padding:1px 4px;border-radius:2px;z-index:1}
/* ── History (prior-run) candidate badge ── */
.tile.hist{border-color:#c07af0}
.tile-hist{position:absolute;top:3px;left:3px;
  background:rgba(150,60,220,.92);color:#fff;font-size:8px;font-weight:700;
  padding:1px 4px;border-radius:2px;z-index:2;line-height:1.3}
/* ── Bottom nav ── */
#bottom-nav{flex-shrink:0;background:#111;border-top:1px solid #222;padding:5px 8px 8px}
.nav-row{display:flex;gap:6px;margin-top:5px}
.nav-btn{height:44px;border:none;border-radius:8px;font-size:15px;
  font-weight:700;cursor:pointer;transition:opacity .15s}
.nav-btn:disabled{opacity:.35;cursor:default}
#back-btn{flex:4;background:#2a2a2a;color:#aaa}
#nap-btn{flex:2;background:#3a1010;color:#cc4444;font-size:14px;border-radius:8px}
#next-btn{flex:4;background:#1e4fa0;color:#fff}
/* ── Below-fold sections ── */
#ebay-section,#manual-section{padding:10px 6px 8px;border-top:1px solid #222;margin-top:4px}
.ebay-lbl,#manual-section label{font-size:10px;color:#555;margin-bottom:4px;display:block}
.kwToolbar{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-top:2px}
.kwStatus{font-size:11px;opacity:.8;min-height:14px;padding-top:4px}
.kwGrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;margin-top:8px}
.kwCard{border:1px solid #2a2a33;border-radius:10px;padding:8px;background:#141418;cursor:pointer}
.kwCard:active{border-color:#63a4ff;background:#1b1b2f}
.kwCard img{width:100%;height:90px;object-fit:contain;border-radius:6px;background:#000}
.kwCard .kw-p{font-weight:700;color:#f39c12;margin-top:4px;font-size:13px}
.kwCard .kw-t{font-size:11px;line-height:1.25;margin-top:4px;max-height:3.5em;overflow:hidden}
#manual-row{display:flex;gap:6px}
#manual-price{flex:1;background:#222;border:1px solid #333;color:#eee;
  border-radius:6px;padding:7px 10px;font-size:14px}
#manual-btn{background:#333;border:none;color:#eee;border-radius:6px;
  padding:7px 12px;font-size:13px;cursor:pointer}
/* ── Progress bar ── */
#prog-wrap{height:4px;background:#2a2a2a;flex-shrink:0}
#prog-fill{height:100%;background:#2a6eff;transition:width .25s;width:0%}
'''

    html = (
        _head('ClickToPrice v2 · ' + ctx['rn'], extra_css)
        + '<div id="hdr">\n'
        + '  <div class="hdr-row">\n'
        + '    <button id="src-back-btn">&#8592;</button>\n'
        + '    <div class="hdr-title">ClickToPrice v2</div>\n'
        + '    <div class="hdr-sub" id="ctp-count"></div>\n'
        + '    <button id="ham-btn">&#9776;</button>\n'
        + '  </div>\n'
        + '  <div id="pin-meta">\n'
        + '    <div class="pm-title" id="pd-title">—</div>\n'
        + '    <div class="pm-right">\n'
        + '      <span class="pm-idx" id="pd-idx"></span>\n'
        + '      <button class="pd-undo" id="undo-btn">&#8617; Undo</button>\n'
        + '    </div>\n'
        + '  </div>\n'
        + '</div>\n'
        + _hamburger_html('new_ctp.html')
        + '<div id="prog-wrap"><div id="prog-fill"></div></div>\n'
        + '''
<div id="tile-area">
  <div id="tile-grid"></div>
  <div id="ebay-section">
    <div class="ebay-lbl">eBay search</div>
    <div class="kwToolbar">
      <input id="ebay-input" type="search" placeholder="Search eBay listings…"
        style="flex:1;min-width:130px;padding:8px;border-radius:8px;border:1px solid #2a2a33;background:#0f0f12;color:#eee;font-size:14px">
      <button id="ebay-btn" class="nav-btn" style="flex:none;padding:8px 12px">Search</button>
      <button id="kwPrev" class="nav-btn" style="flex:none;padding:8px 10px" disabled>◀ 5</button>
      <button id="kwNext" class="nav-btn" style="flex:none;padding:8px 10px" disabled>5 ▶</button>
      <a href="#" id="kwOpenWeb" style="color:#9ec8ff;font-size:12px;white-space:nowrap">Open in tab ↗</a>
    </div>
    <div class="kwStatus" id="kwStatus"></div>
    <div class="kwGrid" id="kwGrid"></div>
  </div>
  <div id="manual-section">
    <label>Manual price override</label>
    <div id="manual-row">
      <input id="manual-price" type="number" step="1" placeholder="0" inputmode="decimal">
      <button id="manual-btn">Set Price</button>
    </div>
  </div>
</div>
<div id="bottom-nav">
  <div class="filter-bar">
    <span class="bar-label">Filter:</span>
    <button class="fb filt-btn active" data-filter="nomatch">No Match<span class="fb-cnt"></span></button>
    <button class="fb filt-btn" data-filter="unrev">Unreviewed<span class="fb-cnt"></span></button>
    <button class="fb filt-btn" data-filter="all">All<span class="fb-cnt"></span></button>
    <button class="fb filt-btn" data-filter="wdi">WDI</button>
    <button class="fb filt-btn" data-filter="dec">DEC</button>
    <button class="fb filt-btn" data-filter="dssh">DSSH</button>
    <button class="fb filt-btn" data-filter="le">LE</button>
  </div>
  <div class="nav-row">
    <button class="nav-btn" id="back-btn">← Back</button>
    <button class="nav-btn" id="nap-btn">NaP</button>
    <button class="nav-btn" id="next-btn">Next →</button>
  </div>
</div>

<script>
''' + data_js + f"const GRAY = '{_GRAY_PLACEHOLDER}';\n" + '''
const STORE_KEY = 'ctp_v2_' + RUN_NAME;
document.getElementById('ctp-count').textContent = PINS.length + ' pins';

let selPin = 0;
let confirmed = {};   // pk -> origIdx  (or -1 for not-a-pin)
let lastUndo  = null;
let curFilter = 'nomatch';
let displayPins = [];

function fmt(p) { return (p != null && !isNaN(p) && p >= 0) ? '$' + Math.round(p) : '$?'; }

function roundMoney2(n) {
  const x = Number(n);
  return Number.isFinite(x) ? Math.round(x + 1e-9) : 0;
}

function candToSelected(c, idx, priceOverride) {
  const pr = priceOverride != null
    ? roundMoney2(priceOverride)
    : roundMoney2(Number((c && c.p) || 0));
  if (!c && priceOverride == null) return {};
  return {
    itemId: String((c && c.itemId) || (c && c.url) || ('slot_' + idx)),
    title: String((c && c.title) || ''),
    itemUrl: String((c && c.url) || ''),
    thumbUrl: String((c && c.thumb) || ''),
    price: pr,
    total_price: pr,
    rank: idx + 1,
  };
}

function chosenIdx(p) {
  if (confirmed[p.pk] != null && confirmed[p.pk] >= 0) return confirmed[p.pk];
  if (p._fbCandIdx != null) return p._fbCandIdx;
  return scriptDefaultIdx(p);
}

function _isPinCommitted(p) {
  return confirmed[p.pk] != null;
}

function scriptDefaultIdx(p) {
  return (p.show_slot != null ? p.show_slot : 0);
}

function advanceNext() {
  if (!displayPins[selPin]) return;
  if (selPin >= displayPins.length - 1) {
    renderPin(selPin);
    return;
  }
  navigate(1);
}

/** Write the same Firebase row shape as index.html ClickToPrice (overlay + collab). */
function _fbCommitPin(p, opts) {
  opts = opts || {};
  const idx = opts.selected_candidate_idx != null
    ? opts.selected_candidate_idx
    : chosenIdx(p);
  const cand = (p.cands || [])[idx] || {};
  const dp = opts.display_price != null
    ? roundMoney2(opts.display_price)
    : roundMoney2(cand.p || p.price || 0);
  const ms = opts.match_status || 'match';
  const listingTitle = opts.listing_title != null
    ? String(opts.listing_title)
    : String(cand.title || p.title || '');
  const scPrice = opts.manual_override ? dp : null;
  const row = {
    pin_key: p.pk,
    board_num: String(p.board_num || ''),
    crop_filename: String(p.crop || ''),
    pin_n: p.pin_n || 0,
    match_status: ms,
    selected_candidate_idx: idx,
    selected_candidate: candToSelected(cand, idx, scPrice),
    display_price: dp,
    listing_title: listingTitle,
    ladder_preserve_zero: dp === 0,
  };
  if (opts.not_a_pin) row.not_a_pin = true;
  p.price = dp;
  p.ms = ms;
  p._fbDirty = true;
  if (!opts.not_a_pin && opts.selected_candidate_idx != null && opts.selected_candidate_idx >= 0) {
    confirmed[p.pk] = opts.selected_candidate_idx;
    if (!opts.manual_override) delete p._manualPrice;
  }
  return _fbWrite(p.pk, row).then(() => {
    _fbToast('Saved', '#1a5e1a');
  });
}

function renderPin(pi) {
  const p = displayPins[pi]; if (!p) return;
  document.getElementById('pd-idx').textContent = (pi+1) + ' / ' + displayPins.length;
  const _pct = displayPins.length > 1 ? Math.round(pi / (displayPins.length-1) * 100) : 100;
  const _fill = document.getElementById('prog-fill');
  if (_fill) { _fill.style.width = _pct+'%'; _fill.style.background = _pct===100 ? '#1a5e1a' : '#2a6eff'; }
  document.getElementById('back-btn').disabled = (pi === 0);
  const isLast = pi === displayPins.length - 1;
  const nextBtn = document.getElementById('next-btn');
  nextBtn.textContent = isLast ? 'Done ✓' : 'Next →';
  nextBtn.style.background = isLast ? '#1a5e1a' : '#1e4fa0';
  document.getElementById('pd-title').textContent = p.title || p.pk;
  document.getElementById('undo-btn').style.display =
    (lastUndo && lastUndo.pk === p.pk) ? 'inline' : 'none';
  const ei = document.getElementById('ebay-input');
  if (ei && !ei.dataset.edited) ei.value = p.title || '';
  renderTiles(p);
  document.getElementById('tile-area').scrollTop = 0;
}

function renderTiles(p) {
  const grid = document.getElementById('tile-grid');
  grid.innerHTML = '';
  const candsWithIdx = (p.cands||[]).map((c, i) => ({...c, origIdx: i}));
  const isNaP = confirmed[p.pk] === -1;
  const isConf = confirmed[p.pk] != null;
  const coi = chosenIdx(p);
  const chosenCand = candsWithIdx[coi] || candsWithIdx[0];
  const chosenPrice = isNaP ? 0
    : (p._manualPrice != null ? p._manualPrice
      : (isConf && p.price != null ? p.price
        : (chosenCand ? (chosenCand.p || p.price) : p.price)));
  const positivePrices = candsWithIdx.filter(c => c.p > 0).map(c => c.p);
  const cheapest = positivePrices.length ? Math.min(...positivePrices) : chosenPrice;
  const pinDelta = isNaP ? 0 : Math.max(0, chosenPrice - cheapest);

  // My Pin tile (first, green left bar)
  const pinTile = document.createElement('div');
  pinTile.className = 'tile pin-tile';
  const pinImg = document.createElement('img');
  pinImg.src = p.b64 || ('../crops/' + encodeURIComponent(p.crop));
  if (!p.b64) { pinImg.onerror = () => { pinImg.src = GRAY; pinImg.onerror = null; }; }
  const pinPbar = document.createElement('div');
  pinPbar.className = 'tile-pbar';
  const pinPr = document.createElement('span');
  pinPr.className = 'tile-price';
  pinPr.textContent = isNaP ? 'NaP' : fmt(chosenPrice);
  const pinDt = document.createElement('span');
  pinDt.className = 'tile-delta';
  pinDt.textContent = isNaP ? '✖' : (pinDelta >= 0.5 ? '−$'+Math.round(pinDelta) : '✓ best');
  pinPbar.append(pinPr, pinDt);
  const pinSn = document.createElement('div');
  pinSn.className = 'tile-sn'; pinSn.textContent = 'S'+coi;
  const pinMypin = document.createElement('div');
  pinMypin.className = 'tile-mypin'; pinMypin.textContent = 'My pin';
  pinTile.append(pinImg, pinPbar, pinSn, pinMypin);
  grid.appendChild(pinTile);

  if (!candsWithIdx.length) return;

  // eBay candidate tiles (ascending price)
  const sorted = candsWithIdx.slice().sort((a,b) => (a.p||0)-(b.p||0));
  sorted.forEach(c => {
    const isChosen = !isNaP && isConf && c.origIdx === coi;
    const dSav = Math.round(chosenPrice - (c.p||0));
    const tile = document.createElement('div');
    tile.className = 'tile'
      + (isChosen ? ' chosen' : '')
      + (isChosen && isConf ? ' confirmed-sel' : '')
      + (c.src === 'history' ? ' hist' : '')
      + (isNaP ? ' not-a-pin' : '');
    const img = document.createElement('img');
    img.src = c.thumb || ''; img.loading = 'lazy';
    img.onerror = () => { img.style.display='none'; };
    if (c.src === 'history') {
      const hb = document.createElement('div');
      hb.className = 'tile-hist';
      hb.textContent = 'PAST' + (c.hdate ? ' · ' + String(c.hdate).slice(0,10) : '');
      tile.appendChild(hb);
    }
    const pbar = document.createElement('div');
    pbar.className = 'tile-pbar';
    const pr = document.createElement('span');
    pr.className = 'tile-price'; pr.textContent = fmt(c.p);
    const dt = document.createElement('span');
    if (isChosen)  { dt.className='tile-delta same';  dt.textContent='chosen'; }
    else if (dSav>0) { dt.className='tile-delta';       dt.textContent='−$'+dSav; }
    else if (dSav<0) { dt.className='tile-delta worse'; dt.textContent='+$'+Math.abs(dSav); }
    else             { dt.className='tile-delta same';  dt.textContent='=$'; }
    pbar.append(pr, dt);
    const sn = document.createElement('div');
    sn.className = 'tile-sn'; sn.textContent = 'S'+c.origIdx;
    tile.append(img, pbar, sn);
    if (isChosen) {
      const star = document.createElement('div');
      star.className = 'tile-star'; star.textContent = '★';
      tile.appendChild(star);
    }
    if (isChosen && isConf) {
      const chk = document.createElement('div');
      chk.className = 'tile-chk'; chk.textContent = '✓';
      tile.appendChild(chk);
    }
    tile.addEventListener('click', () => selectAndAdvance(p, c.origIdx));
    grid.appendChild(tile);
  });
}

function selectAndAdvance(p, origIdx) {
  const prevOrigIdx = confirmed[p.pk];
  const prevPrice = p.price;
  const prevMs = p.ms;
  const cand = (p.cands||[])[origIdx];
  const newPrice = cand ? (cand.p||0) : 0;
  lastUndo = { pk: p.pk, pinI: selPin, prevOrigIdx, prevPrice, prevMs };
  confirmed[p.pk] = origIdx;
  delete p._manualPrice;
  _fbCommitPin(p, {
    selected_candidate_idx: origIdx,
    display_price: newPrice,
    match_status: 'match',
    listing_title: cand ? cand.title : undefined,
  });
  updateFilterCounts();
  navigate(1);
}

function markNotAPin(p) {
  const prevOrigIdx = confirmed[p.pk];
  const prevPrice = p.price;
  const prevMs = p.ms;
  lastUndo = { pk: p.pk, pinI: selPin, prevOrigIdx, prevPrice, prevMs };
  confirmed[p.pk] = -1;
  p.price = 0;
  p.ms = 'not_a_pin';
  _fbCommitPin(p, {
    display_price: 0,
    not_a_pin: true,
    match_status: 'not_a_pin',
  });
  updateFilterCounts();
  navigate(1);
}

function navigate(dir) {
  const newPi = selPin + dir;
  if (newPi < 0 || newPi >= displayPins.length) return;
  if (dir !== 0) lastUndo = null;
  selPin = newPi;
  const ei = document.getElementById('ebay-input');
  if (ei) { ei.value = ''; delete ei.dataset.edited; }
  const _kwg = document.getElementById('kwGrid'); if (_kwg) _kwg.innerHTML = '';
  const _kws = document.getElementById('kwStatus'); if (_kws) _kws.textContent = '';
  const _kwp = document.getElementById('kwPrev'); if (_kwp) _kwp.disabled = true;
  const _kwn = document.getElementById('kwNext'); if (_kwn) _kwn.disabled = true;
  sessionStorage.setItem(STORE_KEY, selPin);
  renderPin(selPin);
}

document.getElementById('back-btn').addEventListener('click', () => { lastUndo = null; navigate(-1); });
document.getElementById('next-btn').addEventListener('click', () => { advanceNext(); });
document.getElementById('nap-btn').addEventListener('click', () => {
  const p = displayPins[selPin]; if (p) markNotAPin(p);
});

document.getElementById('undo-btn').addEventListener('click', () => {
  if (!lastUndo) return;
  const { pk, prevOrigIdx, prevPrice, prevMs } = lastUndo;
  const p = displayPins[selPin];
  if (!p || p.pk !== pk) return;
  if (prevOrigIdx != null && prevOrigIdx >= 0) {
    confirmed[pk] = prevOrigIdx;
    const pc = (p.cands||[])[prevOrigIdx];
    p.price = pc ? (pc.p||0) : prevPrice;
    p.ms = prevMs || 'match';
    _fbCommitPin(p, {
      selected_candidate_idx: prevOrigIdx,
      display_price: p.price,
      match_status: p.ms,
    });
  } else {
    delete confirmed[pk];
    p.price = prevPrice;
    p.ms = prevMs || 'no_match';
    _fbCommitPin(p, {
      selected_candidate_idx: 0,
      display_price: prevPrice || 0,
      match_status: p.ms,
    });
  }
  lastUndo = null;
  updateFilterCounts();
  renderPin(selPin);
});

// ── eBay Proxy Keyword Search ─────────────────────────────────────────────
const _KW_PROXY = 'https://clicktoidentify-proxy.onrender.com';
let _kwProxyReady = null;
function _kwProxyBase() {
  const qp = new URLSearchParams(location.search).get('proxy');
  if (qp) { const s = String(qp).trim(); return (s==='1'||s.toLowerCase()==='dev') ? 'http://127.0.0.1:8091' : s.replace(/\\/+$/, ''); }
  return _KW_PROXY;
}
function _kwWarmProxy() {
  if (!_kwProxyReady) {
    _kwProxyReady = fetch(_kwProxyBase() + '/health', { mode: 'cors', cache: 'no-store' })
      .catch(() => fetch(_kwProxyBase() + '/keyword_search?q=disney+pin&limit=1', { mode: 'cors', cache: 'no-store' }))
      .catch(() => {});
  }
  return _kwProxyReady;
}
_kwWarmProxy();
function _kwFetchJson(url, ms) {
  const ctrl = new AbortController(), t = setTimeout(() => ctrl.abort(), ms);
  return fetch(url, { signal: ctrl.signal, mode: 'cors', cache: 'no-store' })
    .finally(() => clearTimeout(t))
    .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
}
function _kwVariants(q) {
  const base = (q||'').trim(); if (!base) return [];
  const vs = new Set([base]);
  const m = base.match(/^(.+?)\\s*#\\s*(\\d+)$/i);
  if (m) { vs.add(m[1].trim()+' '+m[2]); vs.add(m[1].trim()+' pin '+m[2]); }
  return Array.from(vs);
}
function _kwDedup(items) {
  const seen = new Set(), out = [];
  for (const it of items||[]) { const k=(it.source||'')+'|'+(it.title||'').toLowerCase()+'|'+(it.price||''); if (!seen.has(k)){seen.add(k);out.push(it);} }
  return out;
}
function _kwSortAsc(items) {
  return (items||[]).slice().sort((a,b)=>{ const pa=parseFloat(a&&a.price!=null?a.price:NaN),pb=parseFloat(b&&b.price!=null?b.price:NaN); const na=isFinite(pa)?pa:Infinity,nb=isFinite(pb)?pb:Infinity; return na!==nb?na-nb:String(a&&a.title||'').localeCompare(String(b&&b.title||'')); });
}
async function _kwQueryVariant(v, lim) {
  const data = await _kwFetchJson(_kwProxyBase()+'/keyword_search?q='+encodeURIComponent(v)+'&limit='+lim, 120000);
  let apiError = (data && data.error) ? String(data.error) : null;
  const items = Array.isArray(data && data.items) ? data.items : [];
  return { items, apiError };
}
async function _kwSearch(q, limit) {
  const lim = limit||50;
  const variants = _kwVariants(q);
  if (!variants.length) return { items: [], lastError: null, apiError: null };
  await _kwWarmProxy();
  let merged = [], lastError = null, apiError = null;
  try {
    const first = await _kwQueryVariant(variants[0], lim);
    if (first.apiError && !apiError) apiError = first.apiError;
    merged.push(...first.items);
  } catch (e) { lastError = e; }
  if (merged.length >= 8 || variants.length === 1) {
    return { items: _kwSortAsc(_kwDedup(merged)), lastError, apiError };
  }
  const extra = await Promise.all(variants.slice(1).map(async v => {
    try { return await _kwQueryVariant(v, lim); }
    catch (e) { lastError = lastError || e; return { items: [], apiError: null }; }
  }));
  for (const hit of extra) {
    if (hit.apiError && !apiError) apiError = hit.apiError;
    merged.push(...hit.items);
  }
  return { items: _kwSortAsc(_kwDedup(merged)), lastError, apiError };
}
function _kwPickListing(p, rawItem) {
  const price = Math.round(parseFloat(rawItem.price) || 0);
  const prevOrigIdx = confirmed[p.pk];
  const prevPrice = p.price;
  const prevMs = p.ms;
  const kwCand = {
    p: price,
    thumb: rawItem.thumb || '',
    title: (rawItem.title || '').slice(0, 80),
    url: rawItem.source || rawItem.url || ''
  };
  const rest = (p.cands || []).filter(c => (c.url || '') !== kwCand.url);
  p.cands = [kwCand, ...rest].slice(0, 10);
  confirmed[p.pk] = 0;
  p.price = price;
  if (kwCand.title) p.title = kwCand.title;
  lastUndo = { pk: p.pk, pinI: selPin, prevOrigIdx, prevPrice, prevMs };
  _fbCommitPin(p, {
    selected_candidate_idx: 0,
    display_price: price,
    match_status: 'match',
    listing_title: kwCand.title,
  });
  updateFilterCounts();
  navigate(1);
}
function _kwRenderPage(p) {
  const cur = displayPins[selPin];
  if (!p || !cur || p.pk !== cur.pk) return;
  const grid=document.getElementById('kwGrid'), st=document.getElementById('kwStatus'),
        prev=document.getElementById('kwPrev'), next=document.getElementById('kwNext');
  if (!grid) return;
  const pool = p._kwPool||[], off = Math.max(0, p._kwOff||0), slice = pool.slice(off, off+5);
  if (st) st.textContent = pool.length ? 'Showing '+(off+1)+'–'+(off+slice.length)+' of '+pool.length : '';
  if (prev) prev.disabled = off<=0;
  if (next) next.disabled = off+5>=pool.length;
  grid.innerHTML = '';
  slice.forEach(it => {
    const card = document.createElement('div');
    card.className = 'kwCard';
    const price = Math.round(parseFloat(it.price)||0);
    card.innerHTML = '<img src="'+(it.thumb||'')+'" alt="" onerror="this.style.display=\\'none\\'"><div class="kw-p">$'+price+'</div><div class="kw-t">'+(it.title||'').replace(/&/g,'&amp;').replace(/</g,'&lt;')+'</div>';
    card.addEventListener('click', () => _kwPickListing(p, it));
    grid.appendChild(card);
  });
}
document.getElementById('ebay-input').addEventListener('input', e => { e.target.dataset.edited = '1'; });
document.getElementById('ebay-input').addEventListener('keydown', e => {
  if (e.key === 'Enter') { e.preventDefault(); document.getElementById('ebay-btn').click(); }
});
document.getElementById('kwOpenWeb').addEventListener('click', ev => {
  ev.preventDefault();
  const q = (document.getElementById('ebay-input').value||'').trim();
  if (q) window.open('https://www.ebay.com/sch/i.html?_nkw='+encodeURIComponent(q)+'&LH_Sold=1&LH_Complete=1','_blank');
});
document.getElementById('ebay-btn').addEventListener('click', async () => {
  const p = displayPins[selPin]; if (!p) return;
  const q = (document.getElementById('ebay-input').value||'').trim(); if (!q) return;
  const searchPk = p.pk;
  const st = document.getElementById('kwStatus');
  if (st) st.textContent = 'Searching…';
  try {
    const { items, lastError, apiError } = await _kwSearch(q, 50);
    if (!displayPins[selPin] || displayPins[selPin].pk !== searchPk) return;
    p._kwPool = items; p._kwOff = 0;
    if (!items.length) {
      const parts = [];
      if (apiError) parts.push(apiError);
      if (lastError && lastError.name==='AbortError') parts.push('Timed out — proxy may be cold-starting, try again in 1–2 min.');
      else if (lastError) parts.push(String(lastError.message||lastError));
      parts.push('Proxy: '+_kwProxyBase());
      if (st) st.textContent = 'No results. '+parts.filter(Boolean).join(' ');
    } else if (st) st.textContent = '';
    _kwRenderPage(p);
  } catch(e) {
    if (!displayPins[selPin] || displayPins[selPin].pk !== searchPk) return;
    p._kwPool = [];
    if (st) st.textContent = 'Search failed: '+(e&&e.message?e.message:e);
    _kwRenderPage(p);
  }
});
document.getElementById('kwPrev').addEventListener('click', () => {
  const p = displayPins[selPin]; if (!p) return;
  p._kwOff = Math.max(0, (p._kwOff||0)-5); _kwRenderPage(p);
});
document.getElementById('kwNext').addEventListener('click', () => {
  const p = displayPins[selPin]; if (!p) return;
  const pool = p._kwPool||[], cur = p._kwOff||0;
  if (cur+5 < pool.length) p._kwOff = cur+5; _kwRenderPage(p);
});

document.getElementById('manual-btn').addEventListener('click', () => {
  const p = displayPins[selPin]; if (!p) return;
  const v = parseFloat(document.getElementById('manual-price').value);
  if (isNaN(v) || v <= 0) return;
  const idx = (confirmed[p.pk] != null && confirmed[p.pk] >= 0) ? confirmed[p.pk] : chosenIdx(p);
  p._manualPrice = v;
  _fbCommitPin(p, {
    selected_candidate_idx: idx,
    display_price: v,
    match_status: 'match',
    manual_override: true,
  }).catch(() => {});
  document.getElementById('manual-price').value = '';
  updateFilterCounts();
  renderPin(selPin);
});

function applyFilter() {
  const SKIP = ['match','no_match','auto_match','priced','not_a_pin'];
  let pins = [...PINS];
  if (curFilter === 'nomatch')    pins = pins.filter(p => p.ms === 'no_match');
  else if (curFilter === 'unrev') pins = pins.filter(p => !SKIP.includes(p.ms));
  else if (curFilter !== 'all')   pins = pins.filter(p => (p.cats||[]).includes(curFilter));
  displayPins = pins;
  const saved = parseInt(sessionStorage.getItem(STORE_KEY) || '0', 10);
  selPin = Math.min(saved, Math.max(0, displayPins.length - 1));
  lastUndo = null;
  document.getElementById('ctp-count').textContent = displayPins.length + ' / ' + PINS.length + ' pins';
  updateFilterCounts();
  renderPin(selPin);
}

function updateFilterCounts() {
  const SKIP = ['match','no_match','auto_match','priced','not_a_pin'];
  document.querySelectorAll('.filt-btn').forEach(btn => {
    const span = btn.querySelector('.fb-cnt');
    if (!span) return;
    const f = btn.dataset.filter;
    let cnt;
    if (f === 'all')          cnt = PINS.length;
    else if (f === 'nomatch') cnt = PINS.filter(p => p.ms === 'no_match').length;
    else if (f === 'unrev')   cnt = PINS.filter(p => !SKIP.includes(p.ms)).length;
    else                      cnt = null;
    if (cnt != null) span.textContent = ' (' + cnt + ')';
  });
}

document.querySelectorAll('.filt-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.filt-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    curFilter = btn.dataset.filter;
    sessionStorage.removeItem(STORE_KEY);
    applyFilter();
  });
});

applyFilter();

// Open with ?filter=no_match (or nomatch) from ClickToMatch done link
(function(){
  const urlFilter = new URLSearchParams(window.location.search).get('filter');
  if (urlFilter !== 'no_match' && urlFilter !== 'nomatch') return;
  curFilter = 'nomatch';
  sessionStorage.removeItem(STORE_KEY);
  document.querySelectorAll('.filt-btn').forEach(b => b.classList.remove('active'));
  const btn = document.querySelector('.filt-btn[data-filter="nomatch"]');
  if (btn) btn.classList.add('active');
  applyFilter();
})();

// Jump to specific pin if ?pin= param present
(function(){
  const pk = new URLSearchParams(window.location.search).get('pin');
  if (!pk) return;
  // Force "all" filter so the pin is always visible regardless of its match_status
  curFilter = 'all';
  sessionStorage.removeItem(STORE_KEY);
  document.querySelectorAll('.filt-btn').forEach(b => b.classList.remove('active'));
  const _allBtn = document.querySelector('.filt-btn[data-filter="all"]');
  if (_allBtn) _allBtn.classList.add('active');
  applyFilter();
  const i = displayPins.findIndex(p => p.pk === pk);
  if (i < 0) return;
  selPin = i;
  sessionStorage.setItem(STORE_KEY, i);
  renderPin(i);
  // Show back button — returns to overlay (or contact sheet) at original scroll position
  const _bb = document.getElementById('src-back-btn');
  if (_bb) { _bb.style.display = ''; _bb.onclick = () => history.back(); }
})();
</script>
'''
        + '<script>\n' + _HAMBURGER_JS + '</script>\n'
        + _FB_SDK
        + '''
<script>
// Hydrate CTP from Firebase REST API: update prices, match statuses, and confirmed slots
(async function hydrateCTP() {
  const fbPins = await _fbReadAllPins();
  const keys = Object.keys(fbPins);
  if (!keys.length) {
    console.log('CTP: no Firebase data found for this run — ' + TEST_RUN_ID);
    updateFilterCounts();
    return;
  }
  let updated = 0;
  for (const fbPin of Object.values(fbPins)) {
    const pk = fbPin.pin_key;
    if (!pk) continue;
    const pi = PINS.findIndex(p => p.pk === pk);
    if (pi === -1) continue;
    if (PINS[pi]._fbDirty) continue;
    if (fbPin.display_price != null) { PINS[pi].price = fbPin.display_price; updated++; }
    if (fbPin.match_status) {
      PINS[pi].ms = fbPin.match_status === 'priced' ? 'match' : fbPin.match_status;
    }
    if (fbPin.selected_candidate_idx != null) {
      PINS[pi]._fbCandIdx = fbPin.selected_candidate_idx;
    }
    if (fbPin.match_status === 'not_a_pin') {
      confirmed[PINS[pi].pk] = -1;
    } else if (fbPin.display_price != null && fbPin.match_status !== 'no_match') {
      // Restored from Firebase — treat as confirmed pricing (match or legacy priced).
      if (fbPin.selected_candidate_idx != null) {
        confirmed[PINS[pi].pk] = fbPin.selected_candidate_idx;
      } else {
        confirmed[PINS[pi].pk] = PINS[pi]._fbCandIdx != null ? PINS[pi]._fbCandIdx : chosenIdx(PINS[pi]);
      }
    }
  }
  console.log('CTP: hydrated ' + updated + ' pins from Firebase (' + keys.length + ' entries found)');
  // Re-apply filter with updated statuses then re-check ?pin= param
  const urlPk = new URLSearchParams(window.location.search).get('pin');
  applyFilter();
  if (urlPk) {
    const i = displayPins.findIndex(p => p.pk === urlPk);
    if (i >= 0) { selPin = i; renderPin(i); }
  }
})();
</script>
'''
        + '\n</body></html>'
    )

    out = out_dir / 'new_ctp.html'
    out.write_text(html, encoding='utf-8')
    print(f'  new_ctp.html ({len(records)} pins)')


_OVERLAY_HBG_MARKER = '<!-- __hbg_injected__ -->'


def _patch_index_hamburger(index_path: pathlib.Path) -> None:
    """Inject fixed top-right hamburger nav on the overlay harness index.html."""
    if not index_path.is_file():
        print(f'WARN: {index_path} not found — skipping overlay hamburger')
        return
    html = index_path.read_text(encoding='utf-8')
    links = []
    for href, label in _NAV_LINKS:
        if href == 'index.html':
            links.append(f'<a href="{href}" style="color:#4a9eff;font-weight:600">{label}</a>')
        else:
            links.append(f'<a href="{href}">{label}</a>')
    menu_links = ''.join(links)
    if _OVERLAY_HBG_MARKER in html:
        html = re.sub(
            r'(<div id="_hbg_menu">).*?(</div>)',
            rf'\1{menu_links}\2',
            html,
            count=1,
            flags=re.DOTALL,
        )
        index_path.write_text(html, encoding='utf-8')
        print('Updated overlay hamburger links')
        return
    inject = f'''{_OVERLAY_HBG_MARKER}
<style>
#_hbg_btn{{position:fixed;top:6px;right:6px;z-index:900;
  background:rgba(26,26,26,.92);border:1px solid #444;color:#eee;
  font-size:22px;padding:4px 9px;border-radius:7px;cursor:pointer;line-height:1}}
#_hbg_menu{{display:none;position:fixed;top:0;left:0;right:0;bottom:0;
  z-index:910;background:rgba(0,0,0,.78)}}
#_hbg_menu.open{{display:block}}
#_hbg_menu a{{display:block;background:#222;border-bottom:1px solid #2a2a2a;
  padding:18px 22px;color:#eee;text-decoration:none;font-size:17px}}
#_hbg_menu a:active{{background:#333}}
</style>
<button id="_hbg_btn" aria-label="Menu">&#9776;</button>
<div id="_hbg_menu">{menu_links}</div>
<script>
(function(){{
  var btn=document.getElementById('_hbg_btn');
  var menu=document.getElementById('_hbg_menu');
  btn.addEventListener('click',function(e){{e.stopPropagation();menu.classList.toggle('open');}});
  menu.addEventListener('click',function(e){{if(e.target===this)this.classList.remove('open');}});
}})();
</script>
'''
    if '</body>' not in html:
        print(f'WARN: {index_path} has no </body> — skipping overlay hamburger')
        return
    html = html.replace('</body>', inject + '</body>', 1)
    index_path.write_text(html, encoding='utf-8')
    print(f'Injected overlay hamburger into {index_path.name}')


_OVERLAY_NOMATCH_MARKER = '<!-- __nomatch_ctp_indicator__ -->'

_OVERLAY_NOMATCH_CSS = """
    .pin.nomatch-needs-ctp{border-color:#e33 !important;box-shadow:0 0 0 1px #e33}
    .pin.nomatch-needs-ctp::after{content:'\\2715';position:absolute;top:0;right:0;color:#fff;background:#e33;
      font-size:11px;font-weight:bold;line-height:1;padding:1px 4px;border-radius:0 6px 0 4px;pointer-events:none}
    .overlayRoot.boxes-off .pin.nomatch-needs-ctp::after{display:none}"""

_OVERLAY_NOMATCH_HELPER = """
    function pinNeedsCtpListing(p) {
      if ((p.match_status || "unreviewed") !== "no_match") return false;
      if (p._fbHasListingPick) return false;
      return true;
    }
"""

_OVERLAY_RENDER_PIN_OLD = """          e.className = "pin";
          e.style.left = (100 * p.bbox.x / b.thumb_w) + "%";"""

_OVERLAY_RENDER_PIN_NEW = """          e.className = "pin" + (pinNeedsCtpListing(p) ? " nomatch-needs-ctp" : "");
          e.style.left = (100 * p.bbox.x / b.thumb_w) + "%";"""

_OVERLAY_APPLY_PIN_OLD = """    function applyPinRecord(rec) {
      if (!rec || !rec.pin_key) return false;
      const p = pinByKey(rec.pin_key);
      if (!p) return false;
      if (rec.selected_candidate && typeof rec.selected_candidate === "object") {"""

_OVERLAY_APPLY_PIN_NEW = """    function applyPinRecord(rec) {
      if (!rec || !rec.pin_key) return false;
      const p = pinByKey(rec.pin_key);
      if (!p) return false;
      if (Object.prototype.hasOwnProperty.call(rec, "selected_candidate_idx")) {
        p._fbHasListingPick = (typeof rec.selected_candidate_idx === "number");
      }
      if (rec.selected_candidate && typeof rec.selected_candidate === "object") {
        p._fbHasListingPick = true;"""

_OVERLAY_PIN_CSS_ANCHOR = (
    '.pin{position:absolute;transform:translate(-50%,-50%);display:flex;box-sizing:border-box;'
    'border-radius:8px;cursor:pointer;justify-content:var(--ov-price-h);align-items:var(--ov-price-v);'
    'border:2px solid rgba(99,164,255,.85)}'
)

_OVERLAY_RENDER_ANCHOR = '    function renderOverlay() {'

_OVERLAY_PIN_CLICK_OLD = """          e.onclick = () => {
            const i = pins.findIndex(x => x.pin_key === p.pin_key);
            if (i >= 0) pinIndex = i;
            showPage("ctp");
          };"""

_OVERLAY_PIN_CLICK_NEW = """          e.onclick = () => {
            const pk = p.pin_key || '';
            window.location.href = pk
              ? ('new_ctp.html?pin=' + encodeURIComponent(pk))
              : 'new_ctp.html';
          };"""


def _patch_index_overlay_pin_click(index_path: pathlib.Path) -> None:
    """Overlay harness: pin tap opens ClickToPrice v2 (unfiltered), focused via ?pin=."""
    if not index_path.is_file():
        print(f'WARN: {index_path} not found — skipping overlay pin-click patch')
        return
    html = index_path.read_text(encoding='utf-8')
    if _OVERLAY_PIN_CLICK_NEW.strip() in html:
        print('Overlay pin-click already patched')
        return
    if _OVERLAY_PIN_CLICK_OLD not in html:
        print(f'WARN: {index_path.name} overlay pin onclick block not found — skipping')
        return
    html = html.replace(_OVERLAY_PIN_CLICK_OLD, _OVERLAY_PIN_CLICK_NEW, 1)
    index_path.write_text(html, encoding='utf-8')
    print(f'Patched overlay pin-click in {index_path.name}')


def _patch_index_overlay_nomatch_indicator(index_path: pathlib.Path) -> None:
    """Overlay harness: red border + X on no_match pins without a CTP listing pick."""
    if not index_path.is_file():
        print(f'WARN: {index_path} not found — skipping overlay nomatch indicator')
        return
    html = index_path.read_text(encoding='utf-8')
    if _OVERLAY_NOMATCH_MARKER in html:
        print('Overlay nomatch-needs-ctp indicator already patched')
        return
    changed = False
    if _OVERLAY_PIN_CSS_ANCHOR in html and '.pin.nomatch-needs-ctp' not in html:
        html = html.replace(
            _OVERLAY_PIN_CSS_ANCHOR,
            _OVERLAY_PIN_CSS_ANCHOR + _OVERLAY_NOMATCH_CSS,
            1,
        )
        changed = True
    if _OVERLAY_RENDER_ANCHOR in html and 'function pinNeedsCtpListing' not in html:
        html = html.replace(
            _OVERLAY_RENDER_ANCHOR,
            _OVERLAY_NOMATCH_MARKER + _OVERLAY_NOMATCH_HELPER + _OVERLAY_RENDER_ANCHOR,
            1,
        )
        changed = True
    if _OVERLAY_RENDER_PIN_NEW.strip() not in html:
        if _OVERLAY_RENDER_PIN_OLD in html:
            html = html.replace(_OVERLAY_RENDER_PIN_OLD, _OVERLAY_RENDER_PIN_NEW, 1)
            changed = True
        else:
            print(f'WARN: {index_path.name} overlay pin class block not found — skipping')
    if 'Object.prototype.hasOwnProperty.call(rec, "selected_candidate_idx")' not in html:
        if _OVERLAY_APPLY_PIN_OLD in html:
            html = html.replace(_OVERLAY_APPLY_PIN_OLD, _OVERLAY_APPLY_PIN_NEW, 1)
            changed = True
        else:
            print(f'WARN: {index_path.name} applyPinRecord block not found — skipping')
    if changed:
        index_path.write_text(html, encoding='utf-8')
        print(f'Patched overlay nomatch-needs-ctp indicator in {index_path.name}')
    else:
        print(f'WARN: no overlay nomatch-needs-ctp changes applied to {index_path.name}')


# ── Entry point ────────────────────────────────────────────────────────────
def _load_firebase_export(export_path: pathlib.Path) -> dict:
    """Load pin entries from a Firebase RTDB export JSON file."""
    raw = json.loads(export_path.read_text(encoding='utf-8'))
    for key in ('visual_baseline', 'pins'):
        if isinstance(raw.get(key), dict) and 'pins' in raw.get(key, {}):
            return _fb_pins_by_key(raw[key]['pins'])
        if key == 'pins' and isinstance(raw.get(key), dict):
            return _fb_pins_by_key(raw['pins'])
    # Flat export: top-level values are pin entries.
    if raw and all(isinstance(v, dict) for v in raw.values()):
        return _fb_pins_by_key(raw)
    print(f'WARN: could not parse Firebase export structure in {export_path.name}')
    return {}


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith('-'):
        print(f'Usage: python3 {sys.argv[0]} <run_folder> [--firebase-export path.json]')
        sys.exit(1)

    run_folder = pathlib.Path(args[0]).expanduser().resolve()
    fb_export_path = None
    i = 1
    while i < len(args):
        if args[i] == '--firebase-export' and i + 1 < len(args):
            fb_export_path = pathlib.Path(args[i + 1]).expanduser().resolve()
            i += 2
        else:
            print(f'Unknown argument: {args[i]}')
            sys.exit(1)
    ui_reranked = run_folder / 'testing_ui_visual_baseline' / 'ui_data_reranked.json'
    ui_orig     = run_folder / 'testing_ui_visual_baseline' / 'ui_data.json'
    ui_path     = ui_reranked if ui_reranked.exists() else ui_orig
    idx_path    = run_folder / 'testing_ui_visual_baseline' / 'index.html'
    scores_path = run_folder / 'dinov2_scores.json'
    out_dir     = run_folder / 'testing_ui_visual_baseline'

    if not ui_path.exists():
        print(f'ERROR: {ui_path} not found'); sys.exit(1)

    print(f'Loading {ui_path.name} ...')
    data = json.loads(ui_path.read_text(encoding='utf-8'))
    firebase_cfg, test_run_id, approach_id = _extract_firebase(idx_path)

    scores = {}
    if scores_path.exists():
        for r in json.loads(scores_path.read_text(encoding='utf-8')):
            scores[r['pin_key']] = r

    pins = _build_pins(data, scores)
    crop_dir = run_folder / 'crops'
    print(f'Embedding crop thumbnails ({len(pins)} pins)...')
    _embed_thumbnails(pins, crop_dir)
    run_name = run_folder.name
    ctx = {'fb': firebase_cfg, 'tri': test_run_id, 'api': approach_id, 'rn': run_name}

    fb_pins_by_pk = {}
    if fb_export_path:
        if fb_export_path.is_file():
            fb_pins_by_pk = _load_firebase_export(fb_export_path)
            print(f'  Firebase export: {len(fb_pins_by_pk)} pin entries from {fb_export_path.name}')
        else:
            print(f'WARN: Firebase export not found: {fb_export_path}')

    print(f'Generating enhanced pages for {run_name} ({len(pins)} pins)...')
    _gen_contact_sheet(pins, ctx, out_dir)
    _gen_new_ctm(pins, ctx, out_dir)
    _gen_new_ctp(pins, ctx, out_dir)
    _gen_nts_review(pins, ctx, out_dir, fb_pins_by_pk)
    _patch_index_hamburger(idx_path)
    _patch_index_overlay_pin_click(idx_path)
    _patch_index_overlay_nomatch_indicator(idx_path)
    print('Done.')


if __name__ == '__main__':
    main()
