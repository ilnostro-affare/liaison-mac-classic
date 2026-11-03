import Foundation

/// The page side of translation (0.2.11). Runs only in `BrowserModel.agentWorld`: it shares the DOM, never the page's
/// JavaScript, so its state (`window.__liaTr`) and observer are invisible to the page. It reads text nodes, writes their
/// translated values, and puts the originals back; it never clicks, types or loads anything. One script, `op` picks:
/// detect {lang, sample} the page's declared language and a text sample
/// start - remember "on", watch the DOM for new or changed text
/// collect {nodes: [[id, text]], more, vis} text nodes not sent yet: on screen (the first `vis`), near, the rest
/// onscreen `items` [[id]] -> [id] which of these nodes are on screen now (the person scrolled)
/// apply `items` [[id, text]] -> [[id, original]] writes; answers each node's value before the write
/// changed {dirty, edits: [[id, text]]} since the last ask: new content? text the page itself rewrote?
/// restore `items` [[id, original]] put back, stop watching, forget
/// state {on}
/// selection {text, x, y, w, h, editable} the selection and its viewport rect ("field", "rich", "")
/// replace `text` the selection replaced (only in a field or contenteditable)
enum PageTranslateScript {
    static let js = #"""
    const S = window.__liaTr || (window.__liaTr = { ids: new WeakMap(), nodes: new Map(), sent: new WeakSet(), ours: new Map(), next: 1, on: false, dirty: false, edits: new Map(), obs: null });
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','CODE','PRE','KBD','SAMP','VAR','TEXTAREA','INPUT','SELECT','OPTION','SVG','MATH','CANVAS','IFRAME','TEMPLATE','OBJECT','EMBED','AUDIO','VIDEO']);
    const skipEl = (el) => {
      for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
        if (SKIP.has(e.tagName.toUpperCase())) return true;
        if (e.isContentEditable) return true;
        if (e.getAttribute('aria-hidden') === 'true') return true;
        if (e.getAttribute('translate') === 'no') return true;
        if (e.classList && e.classList.contains('notranslate')) return true;
      }
      return false;
    };
    const idOf = (n) => { let i = S.ids.get(n); if (!i) { i = S.next++; S.ids.set(n, i); S.nodes.set(i, n); } return i; };
    const watch = () => {
      if (S.obs) return;
      S.obs = new MutationObserver((list) => {
        for (const m of list) {
          if (m.type === 'childList') { if (m.addedNodes.length) S.dirty = true; continue; }
          if (m.type === 'characterData') {
            const n = m.target, i = S.ids.get(n);
            if (!i) { S.dirty = true; continue; }
            if (S.ours.get(i) === n.nodeValue) continue;        // our own write
            S.edits.set(i, n.nodeValue);                         // the page rewrote it: a new original
            S.sent.delete(n); S.ours.delete(i); S.dirty = true;
          }
        }
      });
      S.obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    };
    switch (op) {
    case 'detect': {
      const lang = (document.documentElement.getAttribute('lang') || document.documentElement.getAttribute('xml:lang') || '').trim();
      let sample = '';
      try { sample = (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').slice(0, 4000); } catch (e) {}
      return { lang, sample };
    }
    case 'start': S.on = true; watch(); return true;
    case 'state': return { on: !!S.on };
    case 'collect': {
      if (!S.on || !document.body) return { nodes: [], more: false };   // a new document: not ours until start
      const vh = window.innerHeight || 800;
      const seen = [], near = [], far = [];   /* on screen now, the screens around it, the rest */
      const rects = new Map();
      const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode: (n) => {
          if (S.sent.has(n)) return NodeFilter.FILTER_REJECT;
          const v = n.nodeValue;
          if (!v || !/\p{L}/u.test(v)) return NodeFilter.FILTER_REJECT;
          const p = n.parentElement;
          if (!p || skipEl(p)) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      let n, total = 0, more = false;
      while ((n = w.nextNode())) {
        if (total >= max * 3) { more = true; break; }
        const p = n.parentElement;
        let r = rects.get(p);
        if (!r) { r = p.getBoundingClientRect(); rects.set(p, r); }
        if (r.width === 0 && r.height === 0 && p.getClientRects().length === 0) continue;   // not rendered
        (r.bottom >= 0 && r.top <= vh ? seen : (r.bottom >= -vh && r.top <= vh * 2 ? near : far)).push(n);
        total++;
      }
      const pick = seen.concat(near, far);
      if (pick.length > max) more = true;
      const out = [];
      for (const t of pick.slice(0, max)) { S.sent.add(t); out.push([idOf(t), t.nodeValue]); }
      return { nodes: out, more, vis: Math.min(seen.length, max) };
    }
    case 'apply': {
      const before = [];
      if (!S.on) return before;
      for (const [i, text] of items) {
        const n = S.nodes.get(i);
        if (!n || !n.isConnected) continue;
        before.push([i, n.nodeValue]);
        S.ours.set(i, text);
        n.nodeValue = text;
      }
      return before;
    }
    case 'onscreen': {
      const vh = window.innerHeight || 800, out = [], rects = new Map();
      for (const it of items.slice(0, 4000)) {
        const i = it[0], n = S.nodes.get(i);
        const p = n && n.isConnected ? n.parentElement : null;
        if (!p) continue;
        let r = rects.get(p);
        if (!r) { r = p.getBoundingClientRect(); rects.set(p, r); }
        if (r.bottom >= 0 && r.top <= vh && (r.width > 0 || r.height > 0)) out.push(i);
      }
      return out;
    }
    case 'changed': {
      const out = { dirty: !!S.dirty, edits: [...S.edits.entries()] };
      S.dirty = false; S.edits.clear();
      return out;
    }
    case 'restore': {
      if (S.obs) { S.obs.disconnect(); S.obs = null; }
      for (const [i, text] of items) { const n = S.nodes.get(i); if (n && n.isConnected) n.nodeValue = text; }
      S.on = false; S.dirty = false; S.edits.clear(); S.ours.clear(); S.sent = new WeakSet();
      S.nodes.clear(); S.ids = new WeakMap();   /* the page's text nodes are not held after a restore */
      return true;
    }
    case 'selection': {
      const ae = document.activeElement;
      if (ae && (ae.tagName === 'TEXTAREA' || (ae.tagName === 'INPUT' && /^(text|search|url|email|)$/i.test(ae.type || ''))) &&
          typeof ae.selectionStart === 'number' && ae.selectionEnd > ae.selectionStart) {
        const r = ae.getBoundingClientRect();
        S.field = { el: ae, s: ae.selectionStart, e: ae.selectionEnd };
        return { text: ae.value.slice(ae.selectionStart, ae.selectionEnd).slice(0, 5000), x: r.left, y: r.top, w: r.width, h: Math.min(r.height, 40), editable: ae.readOnly || ae.disabled ? '' : 'field' };
      }
      S.field = null;
      const sel = window.getSelection && window.getSelection();
      if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
      const text = String(sel).trim();
      if (!text) return null;
      const range = sel.getRangeAt(0);
      let r = range.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) { const rs = range.getClientRects(); if (rs.length) r = rs[rs.length - 1]; }
      const anchor = sel.anchorNode && (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement);
      return { text: text.slice(0, 5000), x: r.left, y: r.top, w: r.width, h: r.height, editable: anchor && anchor.isContentEditable ? 'rich' : '' };
    }
    case 'replace': {
      const f = S.field;
      if (f && f.el && f.el.isConnected) {
        f.el.focus();
        f.el.setRangeText(text, f.s, f.e, 'select');
        f.el.dispatchEvent(new Event('input', { bubbles: true }));
        return true;
      }
      const sel = window.getSelection && window.getSelection();
      if (!sel || !sel.rangeCount) return false;
      const a = sel.anchorNode && (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement);
      if (!a || !a.isContentEditable) return false;
      return document.execCommand('insertText', false, text);
    }
    }
    return null;
    """#
}
