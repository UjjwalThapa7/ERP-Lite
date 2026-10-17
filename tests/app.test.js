// Loads the inline script of index.html in a fake browser and tests the money logic.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const crypto = require('crypto');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];

function load(queue) {
  const store = {};
  if (queue) store.tkc_queue_v3 = JSON.stringify(queue);
  const el = () => new Proxy(function () {}, {
    get: (t, p) => (p === 'style' ? {} : p === 'value' ? '' : p === 'dataset' ? {} : p === 'classList' ? { contains: () => false } : () => el()),
    set: () => true,
    apply: () => el(),
  });
  const ctx = {
    console, setTimeout, clearTimeout, setInterval: () => 0, Promise, Date, JSON, Math, Object, Array, Set, Number, String, Blob, URL,
    crypto: { randomUUID: () => crypto.randomUUID() },
    localStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }, removeItem: k => { delete store[k]; } },
    navigator: { onLine: true },
    window: { addEventListener() {} },
    document: { querySelector: () => el(), querySelectorAll: () => [], createElement: () => el(), body: el() },
    supabase: { createClient: () => ({ auth: { getSession: async () => ({ data: { session: null } }) }, rpc: async () => ({ error: null }) }) },
  };
  vm.createContext(ctx);
  vm.runInContext(script + '\n;globalThis.__t={cbal,vbal,sum,recompute,products,npr,dayKey,get D(){return D},setServer(v){server=Object.assign(server,v)}};', ctx);
  return ctx.__t;
}

const sale = (o) => ({ id: 's' + Math.random(), ts: Date.now(), subtotal: 0, discount: 0, total: 0, cash: 0, fonepay: 0, credit: 0, items: [], void: false, ...o });

test('page script has no syntax errors and loads', () => { assert.ok(load()); });

test('customer balance = credit sales (not voided) minus payments', () => {
  const t = load();
  t.setServer({
    customers: [{ id: 'c1', name: 'A' }],
    sales: [sale({ customer_id: 'c1', credit: 3000, total: 3000 }), sale({ customer_id: 'c1', credit: 500, total: 500, void: true })],
    cpays: [{ id: 'p1', customer_id: 'c1', ts: Date.now(), cash: 1000, fonepay: 0 }, { id: 'p2', customer_id: 'c1', ts: Date.now(), cash: 0, fonepay: 250 }],
  });
  t.recompute();
  assert.equal(t.cbal().c1, 1750);
});

test('vendor balance = purchases minus payments', () => {
  const t = load();
  t.setServer({ vendors: [{ id: 'v1', name: 'V' }], vtxns: [
    { id: 'a', vendor_id: 'v1', ts: Date.now(), kind: 'purchase', amount: 5000 },
    { id: 'b', vendor_id: 'v1', ts: Date.now(), kind: 'payment', amount: 2000, method: 'Cash' }] });
  t.recompute();
  assert.equal(t.vbal().v1, 3000);
});

test('sum splits cash, fonepay and credit and counts items', () => {
  const t = load();
  const r = t.sum([
    sale({ subtotal: 3000, discount: 200, total: 2800, cash: 1000, fonepay: 800, credit: 1000, items: [{ name: 'Red Kurta', price: 1500, qty: 2 }] }),
    sale({ subtotal: 500, total: 500, cash: 500, items: [{ name: 'red kurta', price: 500, qty: 1 }] })]);
  assert.equal(r.net, 3300); assert.equal(r.cash, 1500); assert.equal(r.fp, 800); assert.equal(r.credit, 1000);
  assert.equal(r.items, 3); assert.equal(r.n, 2);
  assert.equal(Object.keys(r.by).length, 1); // same product, different capitalisation
});

test('queued (offline) entries appear as pending and never duplicate once synced', () => {
  const q = [{ op: 'sale', id: 'q1', ts: Date.now(), subtotal: 100, discount: 0, total: 100, cash: 100, fonepay: 0, credit: 0, items: [{ name: 'X', price: 100, qty: 1 }] }];
  const t = load(q);
  t.recompute();
  assert.equal(t.D.sales.length, 1);
  assert.equal(t.D.sales[0].pending, 1);
  t.setServer({ sales: [sale({ id: 'q1', total: 100 })] });
  t.recompute();
  assert.equal(t.D.sales.length, 1);
  assert.ok(!t.D.sales[0].pending);
});

test('product memory keeps latest price and merges spaces/capitalisation', () => {
  const t = load();
  const now = Date.now();
  t.setServer({ sales: [
    sale({ ts: now - 2000, items: [{ name: 'Red  Cotton Kurta', price: 2500, qty: 1 }] }),
    sale({ ts: now - 1000, items: [{ name: 'red cotton kurta', price: 2700, qty: 1 }] })] });
  t.recompute();
  const p = t.products();
  assert.equal(Object.keys(p).length, 1);
  assert.equal(Object.values(p)[0].price, 2700);
});

test('amounts use Nepali digit grouping', () => { assert.equal(load().npr(100000), 'NPR 1,00,000'); });

test('dates follow Nepal time (UTC+5:45), not UTC', () => {
  assert.equal(load().dayKey(new Date('2026-10-16T19:00:00Z').getTime()), '2026-10-17');
});
