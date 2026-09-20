(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const ui = {
    canvas: $("map-canvas"), viewport: $("map-viewport"), mapEmpty: $("map-empty"),
    mapName: $("map-name"), mapCoordinates: $("map-coordinates"), mapStatus: $("map-status"),
    connectionDot: $("connection-dot"), connectionLabel: $("connection-label"),
    lastSeen: $("last-seen"), playerCount: $("player-count"), npcCount: $("npc-count"),
    focusSelect: $("focus-entity"),
  };
  const ctx = ui.canvas.getContext("2d");
  const model = { state: {}, events: [], history: [], manifest: null, sequence: 0, connected: false, lastUpdate: 0, positioned: false };
  const camera = { x: 8000, y: 8000, scale: 0.75, dragging: false, pointerX: 0, pointerY: 0 };
  const imageCache = new Map();
  let framePending = false;
  let focusOptionsKey = "";

  function requestDraw() {
    if (framePending) return;
    framePending = true;
    window.requestAnimationFrame(() => { framePending = false; drawMap(); });
  }

  function safeNumber(value) {
    return typeof value === "number" && Number.isFinite(value) ? value : null;
  }

  function setConnection(kind, label) {
    ui.connectionDot.className = `status-dot status-${kind}`;
    ui.connectionLabel.textContent = label;
  }

  function formatTime(epoch) {
    const value = Number(epoch) * 1000;
    if (!Number.isFinite(value) || value <= 0) return "—";
    return new Date(value).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  }

  function relativeAge(epoch) {
    const value = Number(epoch) * 1000;
    if (!Number.isFinite(value) || value <= 0) return "never";
    const seconds = Math.max(0, Math.round((Date.now() - value) / 1000));
    if (seconds < 5) return "now";
    if (seconds < 60) return `${seconds}s ago`;
    return `${Math.round(seconds / 60)}m ago`;
  }

  function mapConfig() {
    return model.manifest || { tile_size: 256, tiles: { x_min: 0, x_max: -1, y_min: 0, y_max: -1 }, world: { x_min: 0, x_max: 1, y_min: 0, y_max: 1 } };
  }

  function resizeCanvas() {
    const scale = window.devicePixelRatio || 1;
    const rect = ui.viewport.getBoundingClientRect();
    ui.canvas.width = Math.max(1, Math.round(rect.width * scale));
    ui.canvas.height = Math.max(1, Math.round(rect.height * scale));
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    drawMap();
  }

  function screenSize() {
    const rect = ui.viewport.getBoundingClientRect();
    return { width: rect.width, height: rect.height };
  }

  function screenPoint(x, y) {
    const size = screenSize();
    return { x: (x - camera.x) * camera.scale + size.width / 2, y: (y - camera.y) * camera.scale + size.height / 2 };
  }

  function worldPoint(screenX, screenY) {
    const size = screenSize();
    return { x: camera.x + (screenX - size.width / 2) / camera.scale, y: camera.y + (screenY - size.height / 2) / camera.scale };
  }

  function tileImage(tx, ty, level = 0) {
    const key = `${level}:${tx}:${ty}`;
    if (imageCache.has(key)) {
      const cached = imageCache.get(key);
      imageCache.delete(key); imageCache.set(key, cached);
      return cached;
    }
    const image = new Image();
    image.decoding = "async";
    image.src = model.manifest?.kind === "native-pyramid"
      ? `/map/native/${level}/tile${tx}x${ty}.png?v=${encodeURIComponent(model.manifest.source_sha256 || model.manifest.build)}`
      : `/map/biomemap_${tx}_${ty}.png`;
    image.addEventListener("load", requestDraw, { once: true });
    image.addEventListener("error", () => { if (imageCache.get(key) === image) imageCache.set(key, null); }, { once: true });
    imageCache.set(key, image);
    while (imageCache.size > 384) imageCache.delete(imageCache.keys().next().value);
    return image;
  }

  function drawGrid(size) {
    ctx.save();
    ctx.strokeStyle = "rgba(115, 155, 113, .16)";
    ctx.lineWidth = 1;
    const step = camera.scale > .35 ? 256 : camera.scale > .12 ? 1024 : 2048;
    const left = camera.x - size.width / (2 * camera.scale);
    const right = camera.x + size.width / (2 * camera.scale);
    const top = camera.y - size.height / (2 * camera.scale);
    const bottom = camera.y + size.height / (2 * camera.scale);
    for (let x = Math.floor(left / step) * step; x <= right; x += step) {
      const sx = screenPoint(x, 0).x;
      ctx.beginPath(); ctx.moveTo(sx, 0); ctx.lineTo(sx, size.height); ctx.stroke();
    }
    for (let y = Math.floor(top / step) * step; y <= bottom; y += step) {
      const sy = screenPoint(0, y).y;
      ctx.beginPath(); ctx.moveTo(0, sy); ctx.lineTo(size.width, sy); ctx.stroke();
    }
    ctx.restore();
  }

  function tileLayout(size) {
    const config = mapConfig();
    const native = config.kind === "native-pyramid";
    const level = native ? Math.max(config.min_level, Math.min(config.max_level,
      Math.floor(Math.log2(1 / (camera.scale * (window.devicePixelRatio || 1)))))) : 0;
    const tileSize = (Number(config.tile_size) || 256) * 2 ** level;
    const tiles = config.tiles || {};
    const left = camera.x - size.width / (2 * camera.scale);
    const right = camera.x + size.width / (2 * camera.scale);
    const top = camera.y - size.height / (2 * camera.scale);
    const bottom = camera.y + size.height / (2 * camera.scale);
    const tx0 = Math.max(native ? 0 : Number(tiles.x_min), Math.floor(left / tileSize));
    const tx1 = Math.min(native ? Math.ceil(config.world.x_max / tileSize) - 1 : Number(tiles.x_max), Math.floor(right / tileSize));
    const ty0 = Math.max(native ? 0 : Number(tiles.y_min), Math.floor(top / tileSize));
    const ty1 = Math.min(native ? Math.ceil(config.world.y_max / tileSize) - 1 : Number(tiles.y_max), Math.floor(bottom / tileSize));
    return { level, tileSize, tx0, tx1, ty0, ty1 };
  }

  function drawTiles(size) {
    const { level, tileSize, tx0, tx1, ty0, ty1 } = tileLayout(size);
    if (tx1 < tx0 || ty1 < ty0) return;
    for (let tx = tx0; tx <= tx1; tx += 1) {
      for (let ty = ty0; ty <= ty1; ty += 1) {
        const image = tileImage(tx, ty, level);
        if (!image || !image.complete || !image.naturalWidth) continue;
        const topLeft = screenPoint(tx * tileSize, ty * tileSize);
        ctx.drawImage(image, topLeft.x, topLeft.y, tileSize * camera.scale, tileSize * camera.scale);
      }
    }
  }

  function allEntities() {
    const state = model.state || {};
    const merged = new Map();
    for (const source of [state.entities, state.npcs]) {
      if (!Array.isArray(source)) continue;
      for (const entity of source) {
        if (!entity || typeof entity !== "object") continue;
        const id = entity.npc_id || entity.entity_id || entity.id || entity.name;
        if (!id) continue;
        // Exact telemetry supplies positions; roster telemetry supplies names.
        merged.set(id, { ...entity, ...merged.get(id), id });
      }
    }
    if (state.npc_id && !merged.has(state.npc_id) && safeNumber(state.x) !== null && safeNumber(state.y) !== null) {
      merged.set(state.npc_id, { id: state.npc_id, npc_id: state.npc_id, x: state.x, y: state.y, z: state.z, kind: "goblin", alive: state.npc_alive });
    }
    return [...merged.values()];
  }

  function entityKind(entity) {
    const id = String(entity.npc_id || entity.id || "").toLowerCase();
    const kind = String(entity.kind || "").toLowerCase();
    if (kind === "player" || id.startsWith("player.")) return "player";
    if (kind === "goblin" || id.startsWith("goblin.")) return "goblin";
    return "npc";
  }

  function drawTrail() {
    const trails = new Map();
    for (const row of model.history.slice(-80)) {
      const entities = row && row.state ? (row.state.entities || row.state.npcs || []) : [];
      for (const entity of Array.isArray(entities) ? entities : []) {
        if (!entity) continue;
        const id = entity.entity_id || entity.npc_id || entity.id;
        if (entityKind({ ...entity, id }) !== "goblin") continue;
        const x = safeNumber(entity.x); const y = safeNumber(entity.y);
        if (x === null || y === null) continue;
        if (!trails.has(id)) trails.set(id, []);
        trails.get(id).push(screenPoint(x, y));
      }
    }
    ctx.save(); ctx.strokeStyle = "rgba(153, 227, 107, .52)"; ctx.lineWidth = 2;
    for (const points of trails.values()) {
      if (points.length < 2) continue;
      ctx.beginPath();
      points.forEach((point, index) => index ? ctx.lineTo(point.x, point.y) : ctx.moveTo(point.x, point.y));
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawMarker(entity) {
    const x = safeNumber(entity.x); const y = safeNumber(entity.y);
    if (x === null || y === null) return;
    const point = screenPoint(x, y); const kind = entityKind(entity);
    const radius = kind === "goblin" ? 7 : kind === "player" ? 5 : 4;
    const colors = { goblin: "#99e36b", player: "#6cb4df", npc: "#e2b264", base: "#ec776e" };
    ctx.save();
    if (kind === "goblin") { ctx.shadowBlur = 14; ctx.shadowColor = colors.goblin; }
    ctx.fillStyle = colors[kind]; ctx.beginPath(); ctx.arc(point.x, point.y, radius, 0, Math.PI * 2); ctx.fill();
    ctx.shadowBlur = 0; ctx.fillStyle = "#071009"; ctx.font = "600 10px Segoe UI, sans-serif";
    const label = String(entity.name || (kind === "player" ? String(entity.id).replace(/^player\./, "") : entity.id) || kind).slice(0, 40);
    ctx.fillText(label, point.x + radius + 5, point.y + 3);
    ctx.restore();
  }

  function drawBase() {
    const base = model.state && model.state.base;
    if (!base || typeof base !== "object") return;
    const x = safeNumber(base.x || (base.anchor && base.anchor.x)); const y = safeNumber(base.y || (base.anchor && base.anchor.y));
    if (x === null || y === null) return;
    const point = screenPoint(x, y);
    ctx.save(); ctx.strokeStyle = "#ec776e"; ctx.lineWidth = 2; ctx.strokeRect(point.x - 7, point.y - 7, 14, 14);
    ctx.fillStyle = "#071009"; ctx.font = "600 10px Segoe UI, sans-serif"; ctx.fillText(String(base.name || "BASE"), point.x + 11, point.y + 3); ctx.restore();
  }

  function drawMap() {
    if (!ctx) return;
    const size = screenSize();
    ctx.clearRect(0, 0, size.width, size.height);
    ctx.fillStyle = "#0a100d"; ctx.fillRect(0, 0, size.width, size.height);
    if (model.manifest) drawTiles(size);
    if (model.manifest?.kind !== "native-pyramid") drawGrid(size);
    if ($("show-trails").checked) drawTrail(); drawBase(); allEntities().filter((entity) => $("show-players").checked || entityKind(entity) !== "player").filter((entity) => $("show-goblins").checked || entityKind(entity) !== "goblin").forEach(drawMarker);
    if (!model.manifest) { ui.mapEmpty.hidden = false; ui.mapStatus.textContent = "Map metadata unavailable"; }
    else { ui.mapEmpty.hidden = true; ui.mapStatus.textContent = `zoom ${camera.scale.toFixed(3)} · ${imageCache.size} tiles cached`; }
  }

  function fitWorld() {
    if (!model.manifest) return;
    const world = model.manifest.world; const size = screenSize();
    camera.x = (Number(world.x_min) + Number(world.x_max)) / 2; camera.y = (Number(world.y_min) + Number(world.y_max)) / 2;
    camera.scale = Math.min(size.width / (Number(world.x_max) - Number(world.x_min)), size.height / (Number(world.y_max) - Number(world.y_min))) * .92;
    drawMap();
  }

  function focusGoblin() {
    const goblin = allEntities().find((entity) => entityKind(entity) === "goblin");
    if (!goblin) { ui.mapStatus.textContent = "Goblin position is not available"; return; }
    const x = safeNumber(goblin.x); const y = safeNumber(goblin.y);
    if (x === null || y === null) { ui.mapStatus.textContent = "Goblin position is not available"; return; }
    camera.x = x; camera.y = y; camera.scale = Math.max(camera.scale, .35); drawMap();
  }

  function zoom(factor, anchorX, anchorY) {
    const before = worldPoint(anchorX ?? screenSize().width / 2, anchorY ?? screenSize().height / 2);
    camera.scale = Math.max(.025, Math.min(2.5, camera.scale * factor));
    const after = worldPoint(anchorX ?? screenSize().width / 2, anchorY ?? screenSize().height / 2);
    camera.x += before.x - after.x; camera.y += before.y - after.y; requestDraw();
  }

  function renderSummary() {
    const entities = allEntities();
    const goblin = entities.find((entity) => entityKind(entity) === "goblin");
    ui.playerCount.textContent = entities.filter((entity) => entityKind(entity) === "player").length;
    ui.npcCount.textContent = entities.filter((entity) => entityKind(entity) === "goblin").length;
    ui.lastSeen.textContent = model.state.updated_at ? relativeAge(model.state.updated_at) : "—";
    ui.mapCoordinates.textContent = goblin && safeNumber(goblin.x) !== null && safeNumber(goblin.y) !== null
      ? `x ${Math.round(goblin.x)} · y ${Math.round(goblin.y)} · z ${Math.round(goblin.z || 0)}`
      : "Goblin position not reported";
    const selected = ui.focusSelect.value;
    const optionsKey = JSON.stringify(entities.filter(e => safeNumber(e.x) !== null && safeNumber(e.y) !== null).map(e => [e.id, e.name]));
    if (optionsKey === focusOptionsKey) return;
    focusOptionsKey = optionsKey;
    ui.focusSelect.replaceChildren();
    const placeholder = document.createElement("option");
    placeholder.value = ""; placeholder.textContent = "Find player or Goblin";
    ui.focusSelect.append(placeholder);
    for (const entity of entities) {
      if (safeNumber(entity.x) === null || safeNumber(entity.y) === null) continue;
      const option = document.createElement("option");
      option.value = entity.id;
      option.textContent = entity.name || String(entity.id).replace(/^player\\./, "");
      ui.focusSelect.append(option);
    }
    ui.focusSelect.value = entities.some((entity) => entity.id === selected) ? selected : "";
  }

  function applySnapshot(payload) {
    if (!payload || typeof payload !== "object") return;
    if (payload.state && typeof payload.state === "object") model.state = payload.state;
    if (Array.isArray(payload.events)) model.events = payload.events;
    if (Number.isFinite(payload.sequence)) model.sequence = payload.sequence;
    if (!model.positioned) {
      const entity = allEntities().find((entry) => safeNumber(entry.x) !== null && safeNumber(entry.y) !== null);
      if (entity) { camera.x = entity.x; camera.y = entity.y; camera.scale = .75; model.positioned = true; }
    }
    model.connected = true; model.lastUpdate = Date.now();
    refreshFreshness(); renderSummary(); drawMap();
  }

  function refreshFreshness() {
    if (!model.connected) return;
    const timestamp = Number(model.state.updated_at);
    const stale = !Number.isFinite(timestamp) || timestamp <= 0 || Date.now() / 1000 - timestamp > 30;
    setConnection(stale ? "warn" : "live", stale ? "Last known positions · server idle or stale" : "Tracker live");
  }

  function applyUpdate(payload) { applySnapshot(payload); }

  async function getJson(path) {
    const response = await fetch(path, { cache: "no-store", headers: { Accept: "application/json" } });
    if (!response.ok) throw new Error(`${path}: ${response.status}`);
    return response.json();
  }

  async function loadInitial() {
    const [mapResult, stateResult] = await Promise.allSettled([getJson("/api/map/manifest"), getJson("/api/state")]);
    model.manifest = mapResult.status === "fulfilled" ? mapResult.value : null;
    ui.mapName.textContent = model.manifest?.title || "Map unavailable";
    if (stateResult.status === "fulfilled") applySnapshot({ state: stateResult.value });
    else { setConnection("warn", "Waiting for tracker"); drawMap(); }
    try { const result = await getJson("/api/history/goblin"); model.history = Array.isArray(result.history) ? result.history : []; drawMap(); } catch (_) { /* history is optional */ }
  }

  function startStream() {
    if (!window.EventSource) { setConnection("warn", "Polling fallback"); window.setInterval(() => getJson("/api/state").then((state) => applySnapshot({ state })).catch(() => setConnection("down", "Tracker offline")), 5000); return; }
    const stream = new EventSource("/api/stream");
    stream.addEventListener("snapshot", (event) => { try { applySnapshot(JSON.parse(event.data)); } catch (_) {} });
    stream.addEventListener("update", (event) => { try { applyUpdate(JSON.parse(event.data)); } catch (_) {} });
    stream.addEventListener("error", () => { model.connected = false; setConnection("warn", "Reconnecting to tracker"); });
  }

  ui.canvas.addEventListener("pointerdown", (event) => { ui.canvas.setPointerCapture(event.pointerId); camera.dragging = true; camera.pointerX = event.offsetX; camera.pointerY = event.offsetY; });
  ui.canvas.addEventListener("pointermove", (event) => { if (!camera.dragging) return; camera.x -= (event.offsetX - camera.pointerX) / camera.scale; camera.y -= (event.offsetY - camera.pointerY) / camera.scale; camera.pointerX = event.offsetX; camera.pointerY = event.offsetY; requestDraw(); });
  ui.canvas.addEventListener("pointerup", () => { camera.dragging = false; });
  ui.canvas.addEventListener("pointercancel", () => { camera.dragging = false; });
  ui.canvas.addEventListener("lostpointercapture", () => { camera.dragging = false; });
  ui.canvas.addEventListener("wheel", (event) => { event.preventDefault(); const pixels = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? screenSize().height : 1); zoom(Math.exp(-Math.max(-180, Math.min(180, pixels)) * .002), event.offsetX, event.offsetY); }, { passive: false });
  $("zoom-in").addEventListener("click", () => zoom(1.3));
  $("zoom-out").addEventListener("click", () => zoom(.77));
  $("fit-map").addEventListener("click", fitWorld);
  $("focus-goblin").addEventListener("click", focusGoblin);
  ui.focusSelect.addEventListener("change", () => {
    const entity = allEntities().find((entry) => entry.id === ui.focusSelect.value);
    if (entity) { camera.x = entity.x; camera.y = entity.y; camera.scale = Math.max(camera.scale, .75); drawMap(); }
  });
  for (const id of ["show-players", "show-goblins", "show-trails"]) $(id).addEventListener("change", drawMap);
  window.addEventListener("resize", resizeCanvas);
  window.setInterval(() => { if (model.connected && model.state.updated_at) ui.lastSeen.textContent = relativeAge(model.state.updated_at); refreshFreshness(); }, 5000);
  resizeCanvas(); loadInitial().finally(startStream);
})();
