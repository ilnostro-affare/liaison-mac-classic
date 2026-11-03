import Foundation
import WebKit

/// What the agent sees of a page, read in its own content world (`BrowserModel.agentWorld`): the page's scripts
/// cannot see these functions. On Ads Manager nothing here is a click, a key or an input event; on the open web
/// WebInput sends real clicks and keys, and only a native <select> is set from here (`pick`). The only thing it does to the
/// page is scroll a container (allowed). No computer vision and no word lists of ours: the page's
/// own words go to the Decisions API (`AgentLocator`), which says which element is meant, in any language.
@MainActor
enum AgentBridge {
    /// How a control looks, so what we draw over it matches it.
    struct Style: Equatable {
        var background: String = ""
        var color: String = ""
        var fontSize: CGFloat = 14
        var fontWeight: Int = 400
        var paddingLeft: CGFloat = 8
        var radius: CGFloat = 6
    }

    /// One element of the page as the agent knows it, in the web view's points (origin top-left).
    struct Control: Equatable {
        let ref: Int
        /// Language-free: text, number, select, radio, checkbox, switch, button, link, row, tab, heading, other.
        let kind: String
        /// The page's own words: the element's name, the label beside it, its section, its value.
        let name: String
        let label: String
        let section: String
        let value: String
        let checked: Bool?
        let rect: CGRect
        let style: Style?

        /// One line for the model: the page's words only.
        var line: String {
            var parts = ["e\(ref)", kind]
            if !name.isEmpty { parts.append("«\(name)»") }
            if !label.isEmpty && label != name { parts.append("label «\(label)»") }
            if !section.isEmpty { parts.append("in «\(section)»") }
            if !value.isEmpty && value != name { parts.append("value «\(value)»") }
            if let checked { parts.append(checked ? "on" : "off") }
            return parts.joined(separator: " · ")
        }
    }

    /// Installed on first use in every page (a navigation drops it; the next call puts it back).
    private static let install = #"""
    if (!window.__lia) {
      const refs = new Map(); let seq = 0;
      const ids = new WeakMap();
      const SEL = 'a,button,input,select,textarea,[role=button],[role=link],[role=row],[role=tab],[role=checkbox],[role=radio],[role=switch],[role=combobox],[role=listbox],[role=textbox],[role=spinbutton],[role=menuitem],[role=heading],h1,h2,h3,h4,[contenteditable=true]';
      /* the open web's agent also takes in grid cells, options and clickable divs; Ads Manager's lookups keep the
         narrow set above (its page has thousands of focusable divs that would crowd out the fields) */
      const WIDE = SEL + ',[role=gridcell],[role=option],[onclick],[tabindex="0"],[data-test-id*="arrow" i],[data-test-id*="next" i],[data-test-id*="prev" i],[data-testid*="next" i],[data-testid*="prev" i],[aria-label*="next" i],[aria-label*="prev" i]';
      const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim();
      const short = (s, n) => { s = clean(s); return s.length > n ? s.slice(0, n) + '…' : s; };
      /* an icon-only control (a calendar's next arrow) has no words: its svg title, an image's alt, or the hint in its
         test id or class ("next", "chevron-right") names it */
      const iconName = (el) => {
        const t = el.querySelector && el.querySelector('svg title, img[alt]'); const tt = t ? clean(t.textContent || t.getAttribute('alt')) : '';
        if (tt) return tt;
        const hint = [el.getAttribute('data-test-id'), el.getAttribute('data-testid'), el.getAttribute('data-qa'), typeof el.className === 'string' ? el.className : ''].join(' ');
        const m = hint.match(/(next|prev(ious)?|forward|back|left|right|close|clear|chevron[\w-]*|arrow[\w-]*|plus|minus|increase|decrease|swap|search|menu)/i);
        return m ? 'icon: ' + m[0].toLowerCase() : '';
      };
      const own = (el) => short(el.getAttribute('aria-label') || (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' ? '' : el.innerText) || el.getAttribute('placeholder') || el.title || iconName(el) || '', 90);
      const refOf = (el) => { let k = ids.get(el); if (k) return k; k = ++seq; ids.set(el, k); refs.set(k, new WeakRef(el)); return k; };
      const get = (ref) => { const w = refs.get(ref); return w && w.deref ? w.deref() : null; };
      const box = (el) => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
      const shown = (el) => { const r = el.getBoundingClientRect(); if (r.width < 2 || r.height < 2) return false;
        const cs = getComputedStyle(el); return cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity !== 0; };
      const all = (root, out, sel) => { root.querySelectorAll(sel || SEL).forEach((e) => out.push(e));
        root.querySelectorAll('*').forEach((e) => { if (e.shadowRoot) all(e.shadowRoot, out, sel); }); return out; };
      const kindOf = (el) => {
        const r = (el.getAttribute('role') || '').toLowerCase(), t = el.tagName.toLowerCase(), ty = (el.getAttribute('type') || '').toLowerCase();
        if (r === 'switch') return 'switch';
        if (r === 'checkbox' || ty === 'checkbox') return 'checkbox';
        if (r === 'radio' || ty === 'radio') return 'radio';
        if (r === 'combobox' || r === 'listbox' || t === 'select' || el.getAttribute('aria-haspopup') === 'listbox') return 'select';
        if (r === 'spinbutton' || ty === 'number') return 'number';
        if (t === 'textarea' || r === 'textbox' || el.isContentEditable || (t === 'input' && !/button|submit|hidden|file|image|reset/.test(ty))) return 'text';
        if (r === 'row' || t === 'tr') return 'row';
        if (r === 'tab') return 'tab';
        if (r === 'heading' || /^h[1-4]$/.test(t)) return 'heading';
        if (r === 'link' || t === 'a') return 'link';
        if (r === 'button' || r === 'menuitem' || t === 'button') return 'button';
        return 'other';
      };
      /* the words a person reads as this control's label: aria-labelledby, <label>, else the nearest short text before it */
      const labelOf = (el) => {
        const lb = el.getAttribute('aria-labelledby');
        if (lb) { const t = lb.split(/\s+/).map((i) => { const e = document.getElementById(i); return e ? e.innerText : ''; }).join(' '); if (clean(t)) return short(t, 90); }
        if (el.id) { const l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (l && clean(l.innerText)) return short(l.innerText, 90); }
        const wrap = el.closest('label'); if (wrap && clean(wrap.innerText)) return short(wrap.innerText, 90);
        const me = el.getBoundingClientRect();
        let p = el;
        for (let up = 0; up < 5 && p; up++) {
          p = p.parentElement; if (!p) break;
          let best = null, dist = 1e9;
          for (const n of p.querySelectorAll('span,div,label,p,h1,h2,h3,h4,legend')) {
            if (n === el || n.contains(el) || el.contains(n) || n.children.length > 2) continue;
            const t = clean(n.innerText); if (!t || t.length > 70) continue;
            const r = n.getBoundingClientRect(); if (r.width < 1 || r.height < 1) continue;
            const above = r.bottom <= me.top + 4 && me.top - r.bottom < 60 && r.left < me.right;
            const left = r.right <= me.left + 4 && Math.abs(r.top - me.top) < 24 && me.left - r.right < 240;
            if (!above && !left) continue;
            const d = above ? me.top - r.bottom : (me.left - r.right) / 4;
            if (d < dist) { dist = d; best = t; }
          }
          if (best) return short(best, 90);
        }
        return '';
      };
      /* a calendar day says only "23": the caption over its grid (the month) is the words that make it unique */
      const captionOf = (el) => {
        for (let p = el.parentElement, up = 0; p && up < 7; p = p.parentElement, up++) {
          const g = p.getAttribute('aria-label'); if (g && clean(g).length <= 40 && /[a-zа-я]/i.test(g)) return short(g, 40);
          for (let sb = p.previousElementSibling, k = 0; sb && k < 3; sb = sb.previousElementSibling, k++) {
            const t = clean(sb.innerText); if (t && t.length <= 30 && /[a-zа-яё]{3,}/i.test(t)) return t;
          }
        }
        return '';
      };
      const sectionOf = (el) => {
        for (let p = el.parentElement, up = 0; p && up < 14; p = p.parentElement, up++) {
          const h = p.querySelector(':scope > [role=heading], :scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > div > [role=heading]');
          if (h && !h.contains(el) && clean(h.innerText)) return short(h.innerText, 60);
        }
        return '';
      };
      const valueOf = (el, k) => {
        if (secret(el)) return (el.value || el.innerText) ? '••••' : '';
        if (k === 'text' || k === 'number') return short(el.value != null && el.tagName !== 'DIV' ? el.value : el.innerText, 80);
        if (k === 'select') return short(el.getAttribute('aria-valuetext') || (el.tagName === 'SELECT' ? (el.selectedOptions[0] || {}).text : el.innerText) || el.value || '', 80);
        return '';
      };
      const checkedOf = (el, k) => {
        if (k !== 'checkbox' && k !== 'radio' && k !== 'switch') return null;
        const a = el.getAttribute('aria-checked'); if (a != null) return a === 'true';
        return !!el.checked;
      };
      const styleOf = (el) => { const cs = getComputedStyle(el);
        let bg = cs.backgroundColor, p = el;
        for (let i = 0; i < 6 && p && (/rgba\(0, 0, 0, 0\)|transparent/.test(bg)); i++) { p = p.parentElement; if (p) bg = getComputedStyle(p).backgroundColor; }
        return { background: bg, color: cs.color, fontSize: parseFloat(cs.fontSize) || 14, fontWeight: parseInt(cs.fontWeight) || 400,
                 paddingLeft: parseFloat(cs.paddingLeft) || 8, radius: parseFloat(cs.borderTopLeftRadius) || 6 }; };
      const scroller = (el) => { for (let p = el.parentElement; p; p = p.parentElement) { const cs = getComputedStyle(p);
        if (/(auto|scroll)/.test(cs.overflowY) && p.scrollHeight > p.clientHeight + 4) return p; } return document.scrollingElement || document.documentElement; };
      const hit = (el) => el ? Object.assign({ ref: refOf(el), name: own(el) }, box(el)) : null;
      /* a field a person must fill themselves: passwords (also one shown as text by a "show password" eye, remembered
         from when it was type=password), card numbers, CVC, IBAN, one-time codes. ONE test for the snapshot, the
         controls, the values read back and the typing refusal. */
      /* once per page in this world: the script is re-sent with every call, the memory and the observer must not be */
      const wasPw = window.__liaPw || (window.__liaPw = new WeakSet());
      if (!window.__liaPwObs) { try { window.__liaPwObs = new MutationObserver((rs) => { for (const r of rs) if (String(r.oldValue || '').toLowerCase() === 'password') wasPw.add(r.target); });
        window.__liaPwObs.observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['type'], attributeOldValue: true }); } catch (e) {} }
      const SECRET_WORDS = /(password|passwd|passwort|passcode|pwd|contrase|пароль|mot de passe|cvc|cvv|card.?num|card.?no\b|cc.?num|credit.?card|security.?code|iban|one.?time|(^|[^a-z])otp([^a-z]|$))/i;
      const CARD_WORDS = /(cvc|cvv|card.?num|card.?no\b|cc.?num|credit.?card|security.?code|iban|expir)/i;
      const textish = (el) => { if (!el || el.nodeType !== 1) return false; const t = el.tagName;
        if (t === 'INPUT') return !/^(button|submit|reset|image|checkbox|radio|hidden|file|range|color)$/i.test(el.getAttribute('type') || '');
        return t === 'TEXTAREA' || !!el.isContentEditable || (el.getAttribute('role') || '').toLowerCase() === 'textbox'; };
      const fieldWords = (el) => [el.getAttribute('name'), el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')].filter(Boolean).join(' ');
      const secret = (el) => {
        if (!textish(el)) return false;
        if ((el.getAttribute('type') || '').toLowerCase() === 'password') { wasPw.add(el); return true; }
        if (wasPw.has(el)) return true;
        const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (/password|(^|\s)cc-|one-time-code/.test(ac)) return true;
        if (SECRET_WORDS.test(fieldWords(el))) return true;
        for (const a of el.attributes) if (a.name.indexOf('data-') === 0 && /passw/i.test(a.name + ' ' + a.value)) return true;
        return false;
      };
      /* a card or payment field in a form (its own input, or a payment provider's frame) */
      const cardish = (el) => {
        if (el.tagName === 'IFRAME') return /stripe|braintree|adyen|checkout|payment|paypal|klarna|card/i.test([el.src, el.name, el.title].join(' '));
        if (!textish(el)) return false;
        return /(^|\s)cc-/.test((el.getAttribute('autocomplete') || '').toLowerCase()) || CARD_WORDS.test(fieldWords(el));
      };
      const isSubmit = (b) => (b.tagName === 'BUTTON' && (b.getAttribute('type') || 'submit').toLowerCase() === 'submit')
        || (b.tagName === 'INPUT' && /^(submit|image)$/i.test(b.getAttribute('type') || ''));
      /* What a press would do is decided in Swift (WebGate.reason, tested); the page gives only the
         facts - the control, its words, its link, its form (search, card, message) and the page's address */
      const factsOf = (el) => {
        const b = el.closest('button,[role=button],input[type=submit],input[type=button],input[type=image],a') || el;
        const lab = el.closest('label'), ctl = lab && lab.control;
        const field = textish(b) || b.tagName === 'SELECT' || !!(ctl && /^(checkbox|radio)$/i.test(ctl.type || ''));
        const f = b.form || b.closest('form');
        const fields = f ? [...f.querySelectorAll('input,textarea,select,iframe,[contenteditable=true]')] : [];
        const tag = b.tagName.toLowerCase();
        return { tag, role: b.getAttribute('role') || '', type: b.getAttribute('type') || '', field,
          words: clean([b.innerText, b.tagName === 'INPUT' ? b.value : '', b.getAttribute('aria-label'), b.title, b.tagName === 'INPUT' ? b.getAttribute('alt') : ''].filter(Boolean).join(' ')).toLowerCase().slice(0, 200),
          href: tag === 'a' ? (b.getAttribute('href') || '') : '', hrefAbs: tag === 'a' && b.href ? String(b.href).slice(0, 400) : '',
          submit: isSubmit(b), inForm: !!f, formRole: f ? (f.getAttribute('role') || '') : '', formAction: f ? (f.getAttribute('action') || '').slice(0, 400) : '',
          inSearch: !!b.closest('[role=search]'),
          searchInput: !!f && !!f.querySelector('input[type=search],input[name=q],textarea[name=q],input[name=query],input[name=search]'),
          card: fields.some(cardish), pw: fields.some(secret), textarea: !!f && !!f.querySelector('textarea'), email: !!f && !!f.querySelector('input[type=email]'),
          page: String(location.href).slice(0, 400) };
      };
      window.__lia = {
        /* every visible control, with the page's own words around it (offscreen ones too: the agent can scroll) */
        controls(limit, wide) {
          const seen = new Set(), out = [];
          for (const el of all(document, [], wide ? WIDE : SEL)) {
            if (seen.has(el) || !shown(el)) continue; seen.add(el);
            /* a label is looked for only where a person needs one: a field, or a control without words of its own
               (a calendar day read «Today, 11 October» label «10» - the neighbour's number) */
            /* a secret field's own words never include what is typed in it (a contenteditable's text is its value) */
            const k0 = kindOf(el), n0 = secret(el) ? short(el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.title || '', 90) : own(el);
            const needsLabel = /^(text|number|select|checkbox|radio|switch)$/.test(k0) || !n0;
            const k = k0, name = n0, label = (k === 'heading' || k === 'row' || !needsLabel) ? '' : labelOf(el);
            if (!name && !label && k !== 'text' && k !== 'number' && k !== 'select') continue;
            const field = k === 'text' || k === 'number' || k === 'select';
            out.push(Object.assign({ ref: refOf(el), kind: k, name, label, section: k === 'row' ? '' : (sectionOf(el) || (name.length <= 4 && !label ? captionOf(el) : '')),
              value: valueOf(el, k), checked: checkedOf(el, k), style: field ? styleOf(el) : null }, box(el)));
            if (out.length >= (limit || 400)) break;
          }
          return out;
        },
        /* a table row holding a link or attribute with this id - ids are not words, no language involved */
        row(id) {
          if (!id) return null;
          const el = document.querySelector('a[href*="' + id + '"]') || document.querySelector('[data-id="' + id + '"],[id*="' + id + '"]');
          if (!el) return null;
          return hit(el.closest('[role=row],tr') || el);
        },
        /* The open web - the page as text for the model: its main text, then its controls with ids that stay
           the same between snapshots (a hash of kind, words and section), so a cached prefix and a step's id hold.
           Passwords and card fields are masked; a captcha or a block is named. */
        snap(maxText, maxEls, store) {
          const hash = (s) => { let h = 5381; for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0; return h.toString(36).slice(-4); };
          const cand = [...document.querySelectorAll('main,[role=main],article')].filter(shown)
            .sort((a, b) => (b.innerText || '').length - (a.innerText || '').length);
          let root = cand[0] || document.body;
          if (root !== document.body && (root.innerText || '').length < 400) root = document.body;
          let text = String((root && root.innerText) || '').replace(/[ \t]+/g, ' ').replace(/\n\s*\n\s*\n+/g, '\n\n').trim();
          if (text.length > maxText) text = text.slice(0, maxText) + ' …';
          const ids = new Map(), used = new Map(), recs = [];
          for (const c of (maxEls > 0 ? window.__lia.controls(Math.max(maxEls, 1500), true) : [])) {   /* zoned below, then capped */
            if (c.kind === 'row' || c.kind === 'heading') continue;
            const el = get(c.ref);
            /* the element's own stable handles join its words, so two «23» in a calendar get ids of their own */
            const handle = el ? [el.getAttribute('data-test-id'), el.getAttribute('data-testid'), el.getAttribute('data-qa'), el.getAttribute('name'), el.id,
              el.getAttribute('aria-label'), el.getAttribute('data-date') || el.getAttribute('data-day'), el.tagName === 'A' ? el.getAttribute('href') : ''].filter(Boolean).join('|') : '';
            let id = hash(c.kind + '|' + c.name + '|' + c.label + '|' + c.section + '|' + handle);
            const k = used.get(id) || 0; used.set(id, k + 1); if (k) id += '-' + (k + 1);
            ids.set(id, c.ref);
            let v = c.value; if (el && secret(el)) v = v ? '••••' : '';
            const parts = ['[' + id + ']', c.kind];
            if (c.name) parts.push('«' + c.name + '»');
            if (c.label && c.label !== c.name) parts.push('label «' + c.label + '»');
            if (c.section) parts.push('in «' + c.section + '»');
            if (v && v !== c.name) parts.push('value «' + v + '»');
            if (c.checked != null) parts.push(c.checked ? 'on' : 'off');
            if (c.kind === 'link' && el && el.href) { try { const u = new URL(el.href); parts.push('→ ' + (u.host === location.host ? u.pathname.slice(0, 60) : u.host)); } catch (e) {} }
            if (el && (el.disabled || el.getAttribute('aria-disabled') === 'true')) parts.push('disabled');
            /* state a person sees: chosen, pressed, current, focused (any site, any widget) */
            if (el) {
              const cls = typeof el.className === 'string' ? el.className : '';
              if (el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-pressed') === 'true' || el.getAttribute('aria-current') && el.getAttribute('aria-current') !== 'false'
                  || /(^|[\s_-])(selected|active|is-active|is-selected|current|chosen)([\s_-]|$)/i.test(cls)) parts.push('selected');
              if (el.getAttribute('aria-expanded') === 'true') parts.push('open');
              const fa = document.activeElement; if (fa && fa !== document.body && (fa === el || el.contains(fa))) parts.push('focused');
            }
            /* Where it is - on screen (or just below), hidden to a side, or far up/down the page */
            const side = c.x + c.w < 0 ? 'left' : c.x > innerWidth ? 'right' : '';
            const zone = side ? 'side' : (c.y + c.h < -innerHeight * 0.25 ? 'up' : c.y > innerHeight * 1.5 ? 'down' : 'view');
            if (zone === 'view' && (c.y + c.h < 0 || c.y > innerHeight)) parts.push('(just off screen: scroll)');
            recs.push({ id, kind: c.kind, name: c.name, zone, side, line: parts.join(' '), x: c.x, y: c.y, w: c.w, h: c.h });
          }
          /* listed: what is on screen or near it; long runs of the same control shortened; the rest counted */
          const lines = [], boxes = [];
          let runKey = '', run = 0, skipped = 0;
          const flush = () => { if (skipped) lines.push('  +' + skipped + ' more like the line above'); skipped = 0; };
          for (const rc of recs.filter((x) => x.zone === 'view').slice(0, maxEls)) {
            const key = rc.kind + '|' + rc.name;
            if (key === runKey && rc.name) { run++; if (run > 3) { skipped++; continue; } } else { flush(); runKey = key; run = 1; }
            lines.push(rc.line);
            if (boxes.length < 150 && rc.y + rc.h > 0 && rc.y < innerHeight) boxes.push({ id: rc.id, x: rc.x, y: rc.y, w: rc.w, h: rc.h });
          }
          flush();
          for (const sd of ['right', 'left']) {
            const hid = recs.filter((x) => x.side === sd);
            if (hid.length) lines.push('(' + hid.length + ' more hidden to the ' + sd + ', e.g. ' + hid.slice(0, 6).map((x) => '«' + x.name + '»').join(', ') + ' - show them with the widget\'s own arrow or tab)');
          }
          const down = recs.filter((x) => x.zone === 'down').length, up = recs.filter((x) => x.zone === 'up').length;
          if (down) lines.push('(' + down + ' more controls further down the page - scroll down to see them)');
          if (up) lines.push('(' + up + ' more controls further up the page)');
          if (store !== false) window.__liaIds = ids;   /* only the agent's own snapshot sets the ids its next action uses */
          /* a block only when one is on screen: most sites carry an invisible reCAPTCHA frame on every page
             (aviasales: every step was read as a captcha the person never saw) */
          let blocked = '';
          const seen = (f) => { const r = f.getBoundingClientRect(); return shown(f) && r.width >= 120 && r.height >= 60 && r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth; };
          if ([...document.querySelectorAll('iframe')].some((f) => /recaptcha\/api2\/bframe|recaptcha\/.*anchor|hcaptcha|challenges\.cloudflare|turnstile|captcha/i.test(f.src || '') && seen(f))) blocked = 'a captcha on screen';
          else if (/^(just a moment|attention required|access denied|are you a robot|verify you are human)/i.test(document.title.trim())) blocked = document.title;
          return { text, controls: lines.join('\n'), blocked, boxes, sx: innerWidth, sy: innerHeight };
        },
        /* The page holds still - no DOM change for `calm` ms (at most `max` ms) */
        quiet(calm, max) {
          return new Promise((res) => {
            let last = performance.now(); const t0 = last;
            const mo = new MutationObserver(() => { last = performance.now(); });
            mo.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
            const tick = () => { const now = performance.now();
              if ((now - last >= calm && document.readyState !== 'loading') || now - t0 >= max) { mo.disconnect(); res(Math.round(now - t0)); }
              else setTimeout(tick, 30); };
            setTimeout(tick, 30);
          });
        },
        /* how many pop-ups are open: dialogs, lists, menus (a batch stops when one appears) */
        overlays() {
          return [...document.querySelectorAll('[role=dialog],[aria-modal=true],[role=listbox],[role=menu],dialog[open]')].filter(shown).length;
        },
        /* the choices a field offers after typing: options of a list near it, else new short clickable rows under it */
        options(ref) {
          const f = get(ref); const fr = f ? f.getBoundingClientRect() : { left: 0, bottom: 0, top: 0 };
          let list = [...document.querySelectorAll('[role=option],[role=listbox] li,[role=listbox] [role=menuitem],[role=menu] [role=menuitem],ul[id*="listbox" i] li,[class*="suggest" i] li,[class*="autocomplete" i] li,[class*="dropdown" i] li')].filter(shown);
          if (!list.length) list = [...document.querySelectorAll('li,a,button,[tabindex]')].filter((e) => { if (!shown(e)) return false; const r = e.getBoundingClientRect();
            return r.top >= fr.bottom - 4 && r.top < fr.bottom + 420 && Math.abs(r.left - fr.left) < 320 && clean(e.innerText).length > 0 && clean(e.innerText).length < 160; });
          return list.slice(0, 40).map((e) => ({ ref: refOf(e), text: short(e.innerText || e.getAttribute('aria-label') || '', 140) }));
        },
        /* a calendar day for a date, in any language: by its date attributes, else its label (day number + month name) */
        dayRef(y, m, d) {
          const iso = y + '-' + String(m).padStart(2, '0') + '-' + String(d).padStart(2, '0');
          const dt = new Date(y, m - 1, d);
          const langs = [document.documentElement.lang || navigator.language || 'en', 'en'];
          const months = []; for (const lg of langs) { for (const st of ['long', 'short']) { try { months.push(new Intl.DateTimeFormat(lg, { month: st }).format(dt).toLowerCase().replace('.', '')); } catch (e) {} } try { months.push(new Intl.DateTimeFormat(lg, { month: 'long', day: 'numeric' }).format(dt).toLowerCase().replace(/\d+/g, '').trim()); } catch (e) {} }
          const nums = [iso, iso.replace(/-/g, '/'), String(d).padStart(2, '0') + '.' + String(m).padStart(2, '0') + '.' + y, m + '/' + d + '/' + y, d + '/' + m + '/' + y, String(+dt), String(Math.floor(+dt / 1000))];
          let best = null;
          for (const e of document.querySelectorAll('[data-date],[data-day],[data-value],[datetime],[aria-label],[title],td,[role=gridcell],button')) {
            const attrs = [e.getAttribute('data-date'), e.getAttribute('data-day'), e.getAttribute('data-value'), e.getAttribute('datetime')].filter(Boolean).join(' ');
            const lab = ((e.getAttribute('aria-label') || '') + ' ' + (e.getAttribute('title') || '')).toLowerCase();
            const toks = attrs.split(/[\s,;|]+/);
            const byAttr = attrs && nums.some((n) => toks.indexOf(n) >= 0 || toks.some((t) => t.indexOf('T') > 0 && t.split('T')[0] === n));
            const byLabel = lab && new RegExp('(^|\\D)' + d + '(\\D|$)').test(lab) && months.some((mn) => mn && lab.indexOf(mn) >= 0) && (lab.indexOf(String(y)) >= 0 || !/\b(19|20)\d\d\b/.test(lab));
            if (!byAttr && !byLabel) continue;
            if (e.getAttribute('aria-disabled') === 'true' || e.disabled) continue;
            if (/^(input|textarea)$/i.test(e.tagName)) continue;   /* the date field's own label is not a day */
            const r = e.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
            const inView = r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight;
            const clickable = e.closest('button,[role=gridcell],[role=button],td,a,[tabindex]') || e;
            if (!best || (inView && !best.inView)) best = { ref: refOf(clickable), inView, label: short(lab || attrs, 80) };
            if (inView) break;
          }
          /* the months shown now, to know which way to go */
          /* short visible texts read once (month captions), then each month tested against them */
          const caps = [];
          for (const h of document.querySelectorAll('[role=grid] caption,[class*="month" i],[class*="caption" i],[aria-live],h2,h3,h4,th')) {
            if (caps.length > 200) break;
            const tx = clean(h.textContent).toLowerCase(); if (!tx || tx.length >= 40) continue;
            const rr = h.getBoundingClientRect(); if (rr.width < 1 || rr.bottom < 0 || rr.top > innerHeight) continue;
            caps.push(tx);
          }
          const shownM = [];
          for (let k = -12; k <= 24; k++) { const t = new Date(new Date().getFullYear(), new Date().getMonth() + k, 1);
            const nm = []; for (const lg of langs) { try { nm.push(new Intl.DateTimeFormat(lg, { month: 'long' }).format(t).toLowerCase()); } catch (e) {} }
            const yr = String(t.getFullYear());
            if (caps.some((tx) => nm.some((n) => tx.indexOf(n) >= 0) && (tx.indexOf(yr) >= 0 || !/\d{4}/.test(tx)))) shownM.push(t.getFullYear() * 12 + t.getMonth()); }
          return { day: best, target: y * 12 + (m - 1), shown: shownM };
        },
        /* a calendar's arrow forward or back: by its words or its icon hint, nearest the calendar's days */
        calArrow(forward, near) {
          /* whole words only ("preview", "background", "text-right" are not arrows), nearest the calendar */
          const re = forward ? /(^|[\s_-])(next|forward|following|chevron-?right|arrow-?right|след\S*|вперед|вперёд|successivo|successiva|weiter|suivant|siguiente|próximo)([\s_-]|$)/i
                             : /(^|[\s_-])(prev|previous|back|chevron-?left|arrow-?left|пред\S*|назад|precedente|zurück|précédent|anterior)([\s_-]|$)/i;
          const anchor = get(near); const ar = anchor ? anchor.getBoundingClientRect() : null;
          const cands = [...document.querySelectorAll('button,[role=button],a,[tabindex],[class*="arrow" i],[class*="nav" i]')].filter((e) => {
            if (!shown(e)) return false; const r = e.getBoundingClientRect(); if (r.width > 120 || r.height > 160) return false;
            const words = [e.getAttribute('aria-label'), e.getAttribute('title'), e.getAttribute('data-test-id'), e.getAttribute('data-testid'), typeof e.className === 'string' ? e.className : '', clean(e.innerText)].join(' ');
            return re.test(words) || (forward ? /^[›»>→]$/.test(clean(e.innerText)) : /^[‹«<←]$/.test(clean(e.innerText)));
          }).map((e) => { const r = e.getBoundingClientRect(); const d = ar ? Math.hypot(r.left + r.width / 2 - (ar.left + ar.width / 2), r.top + r.height / 2 - (ar.top + ar.height / 2)) : 0; return { e, d }; })
            .filter((c) => !ar || c.d < 900).sort((a, b) => a.d - b.d);
          return cands.length ? refOf(cands[0].e) : 0;
        },
        /* a native date input: its value set and announced like a person's pick */
        nativeDate(ref, iso) { const el = get(ref); if (!el || el.tagName !== 'INPUT' || !/^(date|datetime-local)$/i.test(el.type)) return false;
          el.value = el.type === 'date' ? iso : iso + 'T00:00'; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return true; },
        /* what pressing it would do: the facts WebGate.reason decides on */
        risk(ref) { const el = get(ref); return el ? factsOf(el) : false; },
        /* Enter in a field submits its form: the field's facts and those of the form's submit buttons */
        enterRisk(ref) {
          for (const el of [get(ref), document.activeElement]) {
            if (!el || el.nodeType !== 1) continue;
            const f = el.form || el.closest('form'); if (!f) continue;
            return { field: factsOf(el), subs: [...f.elements].filter(isSubmit).slice(0, 8).map(factsOf) };
          }
          return { none: true };
        },
        /* a field a person must fill themselves */
        secretField(ref) { const el = get(ref); return !!el && secret(el); },
        /* right before real keys: where they will land now (inside a shadow root or a same-site frame); a frame of
           another site is not readable, so it counts as secret (a card form is often exactly that) */
        activeSecret() {
          let a = document.activeElement;
          for (let i = 0; i < 8 && a; i++) {
            if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
            if (a.tagName === 'IFRAME' || a.tagName === 'FRAME') { let d = null; try { d = a.contentDocument; } catch (e) {} if (!d) return true; a = d.activeElement; continue; }
            break;
          }
          return !!a && secret(a);
        },
        value(ref) { const el = get(ref); if (!el) return ''; if (secret(el)) return (el.value || el.innerText) ? '••••' : ''; return short(el.value != null && el.tagName !== 'DIV' ? el.value : el.innerText, 120); },
        /* where a real click on this element lands on it: its centre is often covered (a tall arrow strip whose middle
           sits over a calendar day - aviasales: "next" picked 18 November). Points inside it are tried until the
           topmost element there is it or inside it. */
        hitPoint(ref) {
          const el = get(ref); if (!el || !el.isConnected) return false;
          const r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false;
          const fx = [0.5, 0.25, 0.75, 0.1, 0.9], fy = [0.5, 0.25, 0.75, 0.1, 0.9];
          let cover = null;
          for (const b of fy) for (const a of fx) {
            const x = r.left + r.width * a, y = r.top + r.height * b;
            if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
            const h = document.elementFromPoint(x, y);
            if (h && (h === el || el.contains(h))) return { x, y, ok: true, tried: fx.indexOf(a) + fy.indexOf(b) * 5 };
            if (!cover && h) cover = own(h) || h.tagName.toLowerCase();
          }
          return { x: r.left + r.width / 2, y: r.top + r.height / 2, ok: false, cover: cover || '' };
        },
        domSize() { return document.getElementsByTagName('*').length + (document.readyState === 'complete' ? 0 : 1e6); },
        byId(id) { const m = window.__liaIds; return (m && m.get(id)) || 0; },
        /* before real keys: the field focused with its text selected, so what is typed replaces it */
        prepType(ref) { const el = get(ref); if (!el) return false; el.focus();
          if (typeof el.select === 'function') { try { el.select(); } catch (e) {} }
          else if (el.isContentEditable) { const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
          return true; },
        /* a native <select> opens a system menu nobody can drive: its option is set and announced as a person's pick */
        pick(ref, option) { const el = get(ref); if (!el || el.tagName !== 'SELECT') return false; const o = clean(option).toLowerCase();
          const opt = [...el.options].find((x) => clean(x.text).toLowerCase() === o) || [...el.options].find((x) => clean(x.text).toLowerCase().includes(o) || String(x.value).toLowerCase() === o);
          if (!opt) return false; el.value = opt.value; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return true; },
        isSelect(ref) { const el = get(ref); return !!el && el.tagName === 'SELECT'; },
        /* the rows of the main table, top to bottom: the geometry a drawn new row copies */
        rows() {
          return [...document.querySelectorAll('[role=row],tr')].filter(shown).map((r) => box(r)).filter((b) => b.h >= 20 && b.w >= 200)
            .sort((a, b) => a.y - b.y).slice(0, 4);
        },
        /* the page's main scrolling area (the biggest visible one) moved by a share of its height: to bring in a
           part of an editor that is drawn only when it is reached. Returns whether it moved. */
        async page(frac) {
          let best = document.scrollingElement || document.documentElement, area = 0;
          for (const el of document.querySelectorAll('*')) {
            if (el.scrollHeight <= el.clientHeight + 40) continue;
            const cs = getComputedStyle(el); if (!/(auto|scroll)/.test(cs.overflowY)) continue;
            const r = el.getBoundingClientRect(); const a = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0)) * r.width;
            if (a > area) { area = a; best = el; }
          }
          const before = best.scrollTop, h = best === document.scrollingElement ? innerHeight : best.clientHeight;
          best.scrollTo({ top: before + h * frac, behavior: 'smooth' });
          let last = -1, same = 0;   /* done as soon as it rests, not after a fixed wait */
          for (let i = 0; i < 16 && same < 2; i++) { await new Promise((res) => setTimeout(res, 40));
            if (Math.abs(best.scrollTop - last) < 0.5) same++; else same = 0; last = best.scrollTop; }
          return Math.abs(best.scrollTop - before) > 4;
        },
        /* scroll the nearest scrolling container so the element sits a third from the top; wait until it settles */
        async reveal(ref) {
          const el = get(ref); if (!el || !el.isConnected) return null;   /* a list drew it again: the old one is gone */
          const sc = scroller(el), r = el.getBoundingClientRect();
          const root = sc === (document.scrollingElement || document.documentElement);
          const top = root ? 0 : sc.getBoundingClientRect().top;
          const h = root ? innerHeight : sc.clientHeight;
          if (r.top < top + 40 || r.bottom > top + h - 40) {
            sc.scrollTo({ top: sc.scrollTop + (r.top - top) - h / 3, behavior: 'smooth' });
            let last = -1, same = 0;
            for (let i = 0; i < 40 && same < 4; i++) { await new Promise((res) => setTimeout(res, 50));
              const now = el.getBoundingClientRect().top; if (Math.abs(now - last) < 0.5) same++; else same = 0; last = now; }
          }
          let after = el.getBoundingClientRect();
          if (after.bottom < 0 || after.top > innerHeight || after.right < 0 || after.left > innerWidth) {   // its own container was not the one that moves it
            el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' });
            await new Promise((res) => setTimeout(res, 450));
          }
          const fin = el.getBoundingClientRect();
          if (!el.isConnected || fin.width < 2 || fin.height < 2) return null;   /* never a point at the corner */
          return hit(el);
        },
      };
    }
    """#

    /// (lag): the whole install script (~30 KB) went with every call, a dozen calls an action, and the
    /// page parsed it each time. Now a call carries only its body; the script goes once per page, when the page says
    /// it does not have it (a navigation drops it).
    private static let missing = "__lia_missing__"

    private static func call(_ webView: WKWebView, _ body: String, _ args: [String: Any] = [:]) async -> Any? {
        let r = await run(webView, "if (!window.__lia) return '" + missing + "';\n" + body, args)
        if let s = r as? String, s == missing { return await run(webView, install + "\n" + body, args) }
        return r
    }

    /// The completion-handler form, so a script that yields nothing can never trap the async bridge; every body
    /// returns `|| false` rather than null.
    private static func run(_ webView: WKWebView, _ script: String, _ args: [String: Any]) async -> Any? {
        await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(script, arguments: args, in: nil, in: BrowserModel.agentWorld) { result in
                switch result {
                case .success(let v): k.resume(returning: v)
                case .failure: k.resume(returning: nil)
                }
            }
        }
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    /// CSS pixels of the page -> points of the web view.
    private static func rect(_ o: [String: Any], in webView: WKWebView) -> CGRect? {
        guard let x = num(o["x"]), let y = num(o["y"]), let w = num(o["w"]), let h = num(o["h"]) else { return nil }
        let k = webView.pageZoom * webView.magnification
        return CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
    }

    static func controls(_ webView: WKWebView, limit: Int = 400) async -> [Control] {
        guard let list = await call(webView, "return window.__lia.controls(limit) || false;", ["limit": limit]) as? [[String: Any]] else { return [] }
        let k = webView.pageZoom * webView.magnification
        return list.compactMap { o in
            guard let ref = (o["ref"] as? NSNumber)?.intValue, let r = rect(o, in: webView) else { return nil }
            var style: Style?
            if let s = o["style"] as? [String: Any] {
                style = Style(background: s["background"] as? String ?? "", color: s["color"] as? String ?? "",
                              fontSize: CGFloat(num(s["fontSize"]) ?? 14) * k, fontWeight: Int(num(s["fontWeight"]) ?? 400),
                              paddingLeft: CGFloat(num(s["paddingLeft"]) ?? 8) * k, radius: CGFloat(num(s["radius"]) ?? 6) * k)
            }
            let kind = o["kind"] as? String ?? "other", name = o["name"] as? String ?? "", label = o["label"] as? String ?? ""
            // Second line behind the page script's own masking: a field named as a secret never shows its value, and
            // no password Liaison filled or saw submitted shows anywhere (SecretMask, PasswordSecrets).
            let raw = PasswordSecrets.scrub(o["value"] as? String ?? "")
            let value = SecretMask.maskedValue(raw, kind: kind, words: name + " " + label)
            return Control(ref: ref, kind: kind, name: PasswordSecrets.scrub(name), label: label,
                           section: o["section"] as? String ?? "", value: value, checked: o["checked"] as? Bool, rect: r, style: style)
        }
    }

    /// A row by the object's id, scrolled into view.
    static func row(_ webView: WKWebView, id: String) async -> (ref: Int, rect: CGRect)? {
        guard let o = await call(webView, "return window.__lia.row(id) || false;", ["id": id]) as? [String: Any],
              let ref = (o["ref"] as? NSNumber)?.intValue else { return nil }
        return await reveal(webView, ref: ref)
    }

    static func rows(_ webView: WKWebView) async -> [CGRect] {
        guard let list = await call(webView, "return window.__lia.rows() || false;") as? [[String: Any]] else { return [] }
        return list.compactMap { rect($0, in: webView) }
    }

    /// Scrolls the element into view when it is outside, and measures it where it came to rest.
    static func reveal(_ webView: WKWebView, ref: Int) async -> (ref: Int, rect: CGRect)? {
        guard let o = await call(webView, "return (await window.__lia.reveal(ref)) || false;", ["ref": ref]) as? [String: Any],
              let r = rect(o, in: webView) else { return nil }
        return (ref, r)
    }

    /// Scrolls the page's main area by a share of its height; false when it could not move further.
    static func scrollPage(_ webView: WKWebView, by frac: Double = 0.7) async -> Bool {
        (await call(webView, "return (await window.__lia.page(frac)) || false;", ["frac": frac]) as? Bool) ?? false
    }

    // MARK: the open web

    /// The page as text for the browse-step model and for Lia's context: main text, then controls with stable ids.
    /// `store`: the agent's own snapshot, whose ids its next action uses (Lia's context snapshot never replaces them).
    static func snapshot(_ webView: WKWebView, maxText: Int = 9000, maxControls: Int = 250, store: Bool = true) async -> (text: String, blocked: String) {
        let s = await snapshotFull(webView, maxText: maxText, maxControls: maxControls, store: store)
        return (s.text, s.blocked)
    }

    /// The snapshot and, for a picture (look), where each listed on-screen control is, in the web view's points.
    static func snapshotFull(_ webView: WKWebView, maxText: Int = 9000, maxControls: Int = 250, store: Bool = true)
        async -> (text: String, blocked: String, boxes: [(id: String, rect: CGRect)]) {
        guard let o = await call(webView, "return window.__lia.snap(maxText, maxEls, store) || false;", ["maxText": maxText, "maxEls": maxControls, "store": store]) as? [String: Any]
        else { return ("", "", []) }
        let text = o["text"] as? String ?? "", controls = o["controls"] as? String ?? ""
        let boxes: [(id: String, rect: CGRect)] = ((o["boxes"] as? [[String: Any]]) ?? []).compactMap { b in
            guard let id = b["id"] as? String, let r = rect(b, in: webView) else { return nil }
            return (id, r)
        }
        // The page script masks password fields; a password Liaison filled or saw submitted is scrubbed from the rest.
        let all = (text.isEmpty ? "" : "TEXT:\n" + text) + (controls.isEmpty ? "" : "\n\nCONTROLS:\n" + controls)
        return (PasswordSecrets.scrub(all), o["blocked"] as? String ?? "", boxes)
    }

    /// Until the page holds still (no DOM change for `calm` ms), at most `max` ms; returns how long it took.
    static func quiet(_ webView: WKWebView, calm: Int = 150, max: Int = 2500) async -> Int {
        (await call(webView, "return (await window.__lia.quiet(calm, max)) || false;", ["calm": calm, "max": max]) as? NSNumber)?.intValue ?? -1
    }

    static func overlays(_ webView: WKWebView) async -> Int {
        (await call(webView, "return window.__lia.overlays() || false;") as? NSNumber)?.intValue ?? 0
    }

    /// The suggestions a field shows after typing.
    static func options(_ webView: WKWebView, field: Int) async -> [(ref: Int, text: String)] {
        ((await call(webView, "return window.__lia.options(ref) || false;", ["ref": field]) as? [[String: Any]]) ?? []).compactMap { o in
            guard let r = (o["ref"] as? NSNumber)?.intValue else { return nil }
            return (r, o["text"] as? String ?? "")
        }
    }

    /// A calendar's day for a date (if any is in the page), the month wanted and the months shown (year*12+month).
    static func dayRef(_ webView: WKWebView, y: Int, m: Int, d: Int) async -> (day: Int?, inView: Bool, target: Int, shown: [Int]) {
        guard let o = await call(webView, "return window.__lia.dayRef(y, m, d) || false;", ["y": y, "m": m, "d": d]) as? [String: Any] else { return (nil, false, 0, []) }
        let day = o["day"] as? [String: Any]
        return ((day?["ref"] as? NSNumber)?.intValue, day?["inView"] as? Bool ?? false, (o["target"] as? NSNumber)?.intValue ?? 0,
                ((o["shown"] as? [NSNumber]) ?? []).map(\.intValue))
    }

    static func calendarArrow(_ webView: WKWebView, forward: Bool, near: Int) async -> Int? {
        let r = (await call(webView, "return window.__lia.calArrow(fw, near) || false;", ["fw": forward, "near": near]) as? NSNumber)?.intValue ?? 0
        return r > 0 ? r : nil
    }

    static func setNativeDate(_ webView: WKWebView, ref: Int, iso: String) async -> Bool {
        (await call(webView, "return window.__lia.nativeDate(ref, iso) || false;", ["ref": ref, "iso": iso]) as? Bool) ?? false
    }

    /// The words of a button that pays, books, sends, deletes, publishes or signs ("" for any other press: links,
    /// searches, filters - WebGate.reason). Fails closed: a script that did not answer is asked about.
    static func risk(_ webView: WKWebView, ref: Int) async -> String {
        guard let o = await call(webView, "return window.__lia.risk(ref) || false;", ["ref": ref]) as? [String: Any] else {
            return "this control (the page could not be checked)"
        }
        return WebGate.reason(WebGate.Facts(o))
    }

    /// Fails closed: a script that did not answer counts as a secret field.
    static func isSecretField(_ webView: WKWebView, ref: Int) async -> Bool {
        (await call(webView, "return window.__lia.secretField(ref) || false;", ["ref": ref]) as? Bool) ?? true
    }

    /// Whether the keys typed now would land in a password, card, CVC, IBAN or one-time-code field (or a frame of
    /// another site). Fails closed.
    static func activeIsSecret(_ webView: WKWebView) async -> Bool {
        (await call(webView, "return window.__lia.activeSecret() || false;") as? Bool) ?? true
    }

    /// The words of a submit button that Enter in this field would press, when it commits something ("" when
    /// harmless: no form, a search form). Fails closed.
    static func enterRisk(_ webView: WKWebView, ref: Int) async -> String {
        guard let o = await call(webView, "return window.__lia.enterRisk(ref) || false;", ["ref": ref]) as? [String: Any] else {
            return "this form (the page could not be checked)"
        }
        if o["none"] != nil { return "" }
        guard let field = o["field"] as? [String: Any] else { return "this form (the page could not be checked)" }
        let subs = (o["subs"] as? [[String: Any]] ?? []).map { WebGate.Facts($0) }
        return WebGate.enterReason(field: WebGate.Facts(field), submits: subs)
    }

    static func value(_ webView: WKWebView, ref: Int) async -> String {
        PasswordSecrets.scrub((await call(webView, "return window.__lia.value(ref) || false;", ["ref": ref]) as? String) ?? "")
    }

    /// Where a click lands on an element found by ref (not by snapshot id), in the web view's points.
    static func revealPoint(_ webView: WKWebView, ref: Int) async -> CGPoint? {
        guard await reveal(webView, ref: ref) != nil, let h = await hitPoint(webView, ref: ref), h.ok,
              webView.bounds.contains(h.point) else { return nil }
        return h.point
    }

    /// The point in the web view (points, top-left origin) where a click lands on the element itself, and whether one
    /// was found (`ok` false: everything there is covered, `cover` names what covers it).
    static func hitPoint(_ webView: WKWebView, ref: Int) async -> (point: CGPoint, ok: Bool, cover: String, tried: Int)? {
        guard let o = await call(webView, "return window.__lia.hitPoint(ref) || false;", ["ref": ref]) as? [String: Any],
              let x = num(o["x"]), let y = num(o["y"]) else { return nil }
        let k = webView.pageZoom * webView.magnification
        return (CGPoint(x: x * k, y: y * k), o["ok"] as? Bool ?? false, o["cover"] as? String ?? "", (o["tried"] as? NSNumber)?.intValue ?? -1)
    }

    /// A cheap measure of the page for "has it settled": its element count (and whether it is still loading).
    static func domSize(_ webView: WKWebView) async -> Int {
        (await call(webView, "return window.__lia.domSize() || false;") as? NSNumber)?.intValue ?? -1
    }

    /// The element behind a snapshot id (the last snapshot of this page).
    static func ref(_ webView: WKWebView, id: String) async -> Int? {
        let r = (await call(webView, "return window.__lia.byId(id) || false;", ["id": id]) as? NSNumber)?.intValue ?? 0
        return r > 0 ? r : nil
    }

    static func prepareTyping(_ webView: WKWebView, ref: Int) async -> Bool {
        (await call(webView, "return window.__lia.prepType(ref) || false;", ["ref": ref]) as? Bool) ?? false
    }

    static func isNativeSelect(_ webView: WKWebView, ref: Int) async -> Bool {
        (await call(webView, "return window.__lia.isSelect(ref) || false;", ["ref": ref]) as? Bool) ?? false
    }

    static func pick(_ webView: WKWebView, ref: Int, option: String) async -> Bool {
        (await call(webView, "return window.__lia.pick(ref, option) || false;", ["ref": ref, "option": option]) as? Bool) ?? false
    }

    /// Everything the agent can see on the page, one line per control: ⌥⌘M, and the model's input.
    static func pageMap(_ webView: WKWebView) async -> String {
        let list = await controls(webView)
        let lines = list.map { c in c.line + String(format: " @(%d,%d,%d,%d)", Int(c.rect.minX), Int(c.rect.minY), Int(c.rect.width), Int(c.rect.height)) }
        return ([webView.url?.absoluteString ?? ""] + lines).joined(separator: "\n")
    }
}
