const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const labels = [];
const context = new Proxy({ fillText: (text) => labels.push(text) }, {
  get: (target, key) => target[key] || (() => {}),
});
const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    textContent: '', className: '', checked: true, value: '', classList: { toggle() {} },
    getContext: () => context, getBoundingClientRect: () => ({ width: 900, height: 600 }),
    addEventListener() {}, replaceChildren() {}, append() {},
  });
  return elements.get(id);
}
const sandbox = {
  document: { getElementById: element, createElement: () => element(Symbol()) },
  window: { devicePixelRatio: 1, addEventListener() {}, setInterval() {}, requestAnimationFrame(fn) { fn(); } },
  Image: class { addEventListener() {} },
  fetch: async () => ({ ok: false, status: 503 }),
};
vm.createContext(sandbox);
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');
vm.runInContext(source.replace('resizeCanvas(); loadInitial().finally(startStream);',
  'globalThis.testMap = { model, camera, allEntities, entityKind, applySnapshot, drawTrail, tileLayout, screenPoint, worldPoint, fitWorld };'), sandbox);
const api = sandbox.testMap;
const goblinId = 'goblin.primary.horse';
const state = {
  updated_at: Date.now() / 1000,
  entities: [
    { entity_id: 'player.horse', kind: 'player', x: 10630, y: 10260 },
    { entity_id: goblinId, kind: 'goblin', x: 10635, y: 10267 },
    { entity_id: 'goblin.primary.unicorn', kind: 'goblin', x: 10638, y: 10265 },
  ],
  npcs: [
    { npc_id: goblinId, name: 'Rattlefang Bucketlurker', alive: true },
    { npc_id: 'goblin.primary.unicorn', name: 'Mudclaw', alive: true },
  ],
};
api.applySnapshot({ state });
assert.equal(elements.get('player-count').textContent, 1);
assert.equal(elements.get('npc-count').textContent, 2);
assert.match(elements.get('map-coordinates').textContent, /10635/);
assert.equal(api.allEntities().length, 3);
assert.equal(api.allEntities()[1].name, 'Rattlefang Bucketlurker');
assert.equal(api.allEntities()[1].x, 10635);
assert.equal(api.entityKind({ id: 'player.goblinfan', kind: 'player' }), 'player');
assert.ok(labels.includes('horse') && labels.includes('Rattlefang Bucketlurker'));
labels.length = 0;
element('show-players').checked = false;
api.applySnapshot({ state });
assert.ok(!labels.includes('horse'), 'player toggle hides player markers');
assert.ok(labels.includes('Rattlefang Bucketlurker'), 'player toggle preserves Goblins');
element('show-players').checked = true;
assert.equal(api.camera.x, 10630);
api.camera.x = 500;
api.applySnapshot({ state });
assert.equal(api.camera.x, 500, 'later updates must preserve manual panning');
api.applySnapshot({ state: { ...state, updated_at: 1 } });
assert.match(elements.get('connection-label').textContent, /Last known/);
api.applySnapshot({ state: { updated_at: Date.now() / 1000, entities: [], npcs: [] } });
assert.equal(api.allEntities().length, 0, 'disconnected players must disappear');
assert.equal(elements.get('map-coordinates').textContent, 'Goblin position not reported');
api.model.history = [{ state }, { state }];
assert.doesNotThrow(() => api.drawTrail());
api.model.manifest = { kind: 'native-pyramid', tile_size: 256, min_level: 0, max_level: 4,
  world: { x_min: 0, y_min: 0, x_max: 19968, y_max: 16128 } };
api.camera.x = 10635; api.camera.y = 10268; api.camera.scale = .75;
let layout = api.tileLayout({ width: 900, height: 600 });
assert.equal(layout.level, 0);
assert.ok(layout.tx0 <= 41 && layout.tx1 >= 41 && layout.ty0 <= 40 && layout.ty1 >= 40);
const center = api.screenPoint(10635, 10268);
assert.equal(center.x, 450); assert.equal(center.y, 300);
assert.equal(api.worldPoint(center.x, center.y).x, 10635);
assert.equal(api.worldPoint(center.x, center.y).y, 10268);
api.fitWorld();
layout = api.tileLayout({ width: 900, height: 600 });
assert.equal(layout.level, 4);
assert.ok((layout.tx1-layout.tx0+1)*(layout.ty1-layout.ty0+1) <= 20, 'world overview needs at most twenty tiles');
console.log('24 live-map regression assertions passed');
