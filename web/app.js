(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const ui = {
    canvas: $("map-canvas"), viewport: $("map-viewport"), mapEmpty: $("map-empty"),
    mapName: $("map-name"), mapCoords: $("map-coordinates"), mapStatus: $("map-status"),
    mapBuild: $("map-build"), connectionDot: $("connection-dot"), connectionLabel: $("connection-label"),
    lastSeen: $("last-seen"), goblinState: $("goblin-state"), bodyMode: $("body-mode"),
    serverStatus: $("server-status"), playerCount: $("player-count"), npcCount: $("npc-count"),
    goblinNote: $("goblin-note"), eventCount: $("event-count"), eventList: $("event-list"),
    historyCount: $("history-count"),
  };
  const ctx = ui.canvas.getContext("2d");
  const model = { state: {}, events: [], history: [], manifest: null, sequence: 0, connected: false, lastUpdate: 0 };
  const camera = { x: 8000, y: 8000, scale: 0.12, dragging: false, pointerX: 0, pointerY: 0 };
  const imageCache = new Map();

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

  function tileImage(tx, ty) {
    const key = `${tx}:${ty}`;
    if (imageCache.has(key)) return imageCache.get(key);
    const image = new Image();
    image.decoding = "async";
    image.src = `/map/biomemap_${tx}_${ty}.png`;
    image.addEventListener("load", () => drawMap(), { once: true });
    image.addEventListener("error", () => imageCache.set(key, null), { once: true });
    imageCache.set(key, image);
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

  function drawTiles(size) {
    const config = mapConfig();
    const tileSize = Number(config.tile_size) || 256;
    const tiles = config.tiles || {};
    const left = camera.x - size.width / (2 * camera.scale);
    const right = camera.x + size.width / (2 * camera.scale);
    const top = camera.y - size.height / (2 * camera.scale);
    const bottom = camera.y + size.height / (2 * camera.scale);
    const tx0 = Math.max(Number(tiles.x_min), Math.floor(left / tileSize));
    const tx1 = Math.min(Number(tiles.x_max), Math.floor(right / tileSize));
    const ty0 = Math.max(Number(tiles.y_min), Math.floor(top / tileSize));
    const ty1 = Math.min(Number(tiles.y_max), Math.floor(bottom / tileSize));
    if (tx1 < tx0 || ty1 < ty0) return;
    for (let tx = tx0; tx <= tx1; tx += 1) {
      for (let ty = ty0; ty <= ty1; ty += 1) {
        const image = tileImage(tx, ty);
        if (!image || !image.complete || !image.naturalWidth) continue;
        const topLeft = screenPoint(tx * tileSize, ty * tileSize);
        ctx.drawImage(image, topLeft.x, topLeft.y, tileSize * camera.scale, tileSize * camera.scale);
      }
    }
  }

  function allEntities() {
    const state = model.state || {};
    const output = [];
    const seen = new Set();
    for (const source of [state.entities, state.npcs]) {
      if (!Array.isArray(source)) continue;
      for (const entity of source) {
        if (!entity || typeof entity !== "object") continue;
        const id = entity.npc_id || entity.entity_id || entity.id || entity.name;
        if (!id || seen.has(id)) continue;
        seen.add(id); output.push({ ...entity, id });
      }
    }
    if (state.npc_id && !seen.has(state.npc_id) && safeNumber(state.x) !== null && safeNumber(state.y) !== null) {
      output.push({ id: state.npc_id, npc_id: state.npc_id, x: state.x, y: state.y, z: state.z, kind: "npc", alive: state.npc_alive });
    }
    return output;
  }

  function entityKind(entity) {
    const id = String(entity.npc_id || entity.id || "").toLowerCase();
    const kind = String(entity.kind || "").toLowerCase();
    if (id === "goblin.primary" || id.includes("goblin")) return "goblin";
    if (kind === "player" || entity.online === true) return "player";
    return "npc";
  }

  function drawTrail() {
    const points = [];
    for (const row of model.history.slice(-80)) {
      const entities = row && row.state ? (row.state.entities || row.state.npcs || []) : [];
      const goblin = Array.isArray(entities) ? entities.find((entity) => entity && (entity.npc_id || entity.id) === "goblin.primary") : null;
      const x = safeNumber(goblin && goblin.x); const y = safeNumber(goblin && goblin.y);
      if (x !== null && y !== null) points.push(screenPoint(x, y));
    }
    if (points.length < 2) return;
    ctx.save(); ctx.beginPath(); ctx.strokeStyle = "rgba(153, 227, 107, .52)"; ctx.lineWidth = 2;
    points.forEach((point, index) => index ? ctx.lineTo(point.x, point.y) : ctx.moveTo(point.x, point.y));
    ctx.stroke(); ctx.restore();
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
    const label = kind === "goblin" ? "GOBLIN" : String(entity.name || entity.id || kind).slice(0, 18);
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
    drawGrid(size); drawTrail(); drawBase(); allEntities().forEach(drawMarker);
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
    camera.x += before.x - after.x; camera.y += before.y - after.y; drawMap();
  }

  function renderSummary() {
    const state = model.state || {}; const entities = allEntities();
    const goblin = entities.find((entity) => entityKind(entity) === "goblin");
    const alive = state.npc_alive === true || (goblin && goblin.alive !== false);
    ui.goblinState.textContent = alive ? "ALIVE" : state.npc_alive === false ? "OFFLINE" : "UNKNOWN";
    ui.goblinState.className = `state-badge ${alive ? "state-alive" : state.npc_alive === false ? "state-dead" : "state-unknown"}`;
    ui.bodyMode.textContent = state.body_mode || "—";
    ui.serverStatus.textContent = state.server_status || "—";
    ui.playerCount.textContent = state.player_count ?? entities.filter((entity) => entityKind(entity) === "player").length;
    ui.npcCount.textContent = entities.filter((entity) => entityKind(entity) !== "player").length;
    ui.lastSeen.textContent = state.updated_at ? relativeAge(state.updated_at) : "—";
    if (goblin && safeNumber(goblin.x) !== null && safeNumber(goblin.y) !== null) {
      ui.mapCoordinates.textContent = `x ${Math.round(goblin.x)} · y ${Math.round(goblin.y)}${safeNumber(goblin.z) !== null ? ` · z ${Math.round(goblin.z)}` : ""}`;
    } else ui.mapCoordinates.textContent = "Goblin position not reported";
    ui.goblinNote.textContent = alive ? "Bandits2 body is present; GoblinSurvivor policy controls friendliness and intent." : "The body is not currently alive. The recovery policy can create a replacement when the server is ready.";
  }

  function renderEvents() {
    const events = model.events.slice(-32).reverse();
    ui.eventCount.textContent = String(events.length);
    ui.eventList.replaceChildren();
    if (!events.length) { const row = document.createElement("li"); row.className = "empty-row"; row.textContent = "No events recorded."; ui.eventList.append(row); return; }
    for (const event of events) {
      const row = document.createElement("li"); row.className = "event-row";
      const top = document.createElement("div"); top.className = "event-top";
      const kind = document.createElement("span"); kind.className = "event-kind"; kind.textContent = String(event.kind || "event").replaceAll("_", " ");
      const time = document.createElement("time"); time.className = "event-time"; time.textContent = formatTime(event.observed_at);
      top.append(kind, time);
      const text = document.createElement("div"); text.className = "event-text";
      text.textContent = event.text || event.reason || [event.player, event.role, event.job].filter(Boolean).join(" · ") || "telemetry update";
      row.append(top, text); ui.eventList.append(row);
    }
  }

  function renderHistory() {
    ui.historyCount.textContent = `${model.history.length} points`;
  }

  function applySnapshot(payload) {
    if (!payload || typeof payload !== "object") return;
    if (payload.state && typeof payload.state === "object") model.state = payload.state;
    if (Array.isArray(payload.events)) model.events = payload.events;
    if (Number.isFinite(payload.sequence)) model.sequence = payload.sequence;
    model.connected = true; model.lastUpdate = Date.now();
    setConnection("live", "Tracker live"); renderSummary(); renderEvents(); drawMap();
  }

  function applyUpdate(payload) { applySnapshot(payload); }

  async function getJson(path) {
    const response = await fetch(path, { cache: "no-store", headers: { Accept: "application/json" } });
    if (!response.ok) throw new Error(`${path}: ${response.status}`);
    return response.json();
  }

  async function loadInitial() {
    try { model.manifest = await getJson("/api/map/manifest"); ui.mapName.textContent = model.manifest.title || "B42 map layer"; ui.mapBuild.textContent = `${model.manifest.build || "B42"} · ${model.manifest.source || "map cache"}`; drawMap(); }
    catch (_) { model.manifest = null; ui.mapName.textContent = "B42 map layer unavailable"; drawMap(); }
    try { applySnapshot({ state: await getJson("/api/state") }); } catch (_) { setConnection("warn", "Waiting for tracker"); }
    try { const result = await getJson("/api/events"); model.events = Array.isArray(result.events) ? result.events : []; renderEvents(); } catch (_) { /* stream can still recover */ }
    try { const result = await getJson("/api/history/goblin"); model.history = Array.isArray(result.history) ? result.history : []; renderHistory(); drawMap(); } catch (_) { /* history is optional */ }
  }

  function startStream() {
    if (!window.EventSource) { setConnection("warn", "Polling fallback"); window.setInterval(() => getJson("/api/state").then((state) => applySnapshot({ state })).catch(() => setConnection("down", "Tracker offline")), 5000); return; }
    const stream = new EventSource("/api/stream");
    stream.addEventListener("snapshot", (event) => { try { applySnapshot(JSON.parse(event.data)); } catch (_) {} });
    stream.addEventListener("update", (event) => { try { applyUpdate(JSON.parse(event.data)); } catch (_) {} });
    stream.addEventListener("error", () => { model.connected = false; setConnection("warn", "Reconnecting to tracker"); });
  }

  ui.canvas.addEventListener("pointerdown", (event) => { ui.canvas.setPointerCapture(event.pointerId); camera.dragging = true; camera.pointerX = event.offsetX; camera.pointerY = event.offsetY; });
  ui.canvas.addEventListener("pointermove", (event) => { if (!camera.dragging) return; camera.x -= (event.offsetX - camera.pointerX) / camera.scale; camera.y -= (event.offsetY - camera.pointerY) / camera.scale; camera.pointerX = event.offsetX; camera.pointerY = event.offsetY; drawMap(); });
  ui.canvas.addEventListener("pointerup", () => { camera.dragging = false; });
  ui.canvas.addEventListener("pointercancel", () => { camera.dragging = false; });
  ui.canvas.addEventListener("wheel", (event) => { event.preventDefault(); zoom(event.deltaY < 0 ? 1.18 : .85, event.offsetX, event.offsetY); }, { passive: false });
  $("zoom-in").addEventListener("click", () => zoom(1.3));
  $("zoom-out").addEventListener("click", () => zoom(.77));
  $("fit-map").addEventListener("click", fitWorld);
  $("focus-goblin").addEventListener("click", focusGoblin);
  window.addEventListener("resize", resizeCanvas);
  window.setInterval(() => { if (model.connected && model.state.updated_at) ui.lastSeen.textContent = relativeAge(model.state.updated_at); }, 5000);
  resizeCanvas(); loadInitial().finally(startStream);
})();
