"use strict";

const HOST_NAME = "hyprland_zen_bridge";
const ENABLE_CONSOLE_FALLBACK = true;
const RECONNECT_DELAY_MS = 1500;
const MAX_NATIVE_MESSAGE_BYTES = 900 * 1024;
const PREVIEW_TARGET_BYTES = 700 * 1024;
const PREVIEW_MAX_DIMENSION = 1600;
const PREVIEW_QUALITY_STEPS = [0.62, 0.5, 0.4, 0.32, 0.26];
const PREVIEW_SCALE_STEPS = [1.0, 0.85, 0.7, 0.55, 0.42];

let nativePort = null;
let reconnectTimer = null;

function messageBytes(message) {
  try {
    return new TextEncoder().encode(JSON.stringify(message)).length;
  } catch (_err) {
    return Number.POSITIVE_INFINITY;
  }
}

function postNative(message) {
  if (!nativePort) {
    return false;
  }
  try {
    nativePort.postMessage(message);
    return true;
  } catch (err) {
    nativePort = null;
    if (ENABLE_CONSOLE_FALLBACK) {
      console.warn("[hyprland-zen-extension] post failed", {
        reason: err?.message || String(err),
        op: message?.op,
        type: message?.type,
      });
    }
    scheduleReconnect();
    return false;
  }
}

function workspaceKey(tab) {
  return `win:${tab.windowId}`;
}

function workspaceName(tab) {
  return `Window ${tab.windowId}`;
}

function workspacePayloadFromTab(tab) {
  return {
    browser: "zen",
    profile: "default",
    workspace_id: workspaceKey(tab),
    name: workspaceName(tab),
    active: !!tab.active,
    window_id: tab.windowId,
    cookie_store_id: tab.cookieStoreId || "default"
  };
}

function tabPayload(tab) {
  const cookieStoreId = tab.cookieStoreId || "default";
  return {
    browser: "zen",
    profile: "default",
    workspace_id: workspaceKey(tab),
    workspace_name: workspaceName(tab),
    sync_group: `container:${cookieStoreId}`,
    tab_id: String(tab.id),
    window_id: String(tab.windowId),
    url: tab.url || "",
    title: tab.title || "<untitled tab>",
    audible: !!tab.audible,
    pinned: !!tab.pinned,
    active: !!tab.active,
    hidden: !!tab.hidden,
    discarded: !!tab.discarded,
    cookie_store_id: cookieStoreId,
    status: tab.status || "",
    last_seen: Date.now()
  };
}

function uniqueWorkspaces(tabs) {
  const map = new Map();
  for (const tab of tabs) {
    const key = workspaceKey(tab);
    if (!map.has(key)) {
      map.set(key, workspacePayloadFromTab(tab));
    }
    if (tab.active) {
      map.get(key).active = true;
    }
  }
  return [...map.values()];
}

function send(message) {
  if (!nativePort) {
    scheduleReconnect();
    if (ENABLE_CONSOLE_FALLBACK) {
      console.debug("[hyprland-zen-extension]", message);
    }
    return;
  }
  const bytes = messageBytes(message);
  if (bytes > MAX_NATIVE_MESSAGE_BYTES) {
    if (ENABLE_CONSOLE_FALLBACK) {
      console.warn("[hyprland-zen-extension] message too large", {
        bytes,
        type: message?.type,
        op: message?.op
      });
    }
    postNative({
      type: "error",
      op: String(message?.op || message?.type || "send"),
      message: `native-message-too-large:${bytes}`
    });
    return;
  }
  if (!postNative(message) && ENABLE_CONSOLE_FALLBACK) {
    console.debug("[hyprland-zen-extension]", message);
  }
}

function sendError(op, reason) {
  send({
    type: "error",
    op,
    message: reason
  });
}

async function sendSnapshot() {
  const tabs = await browser.tabs.query({});
  send({
    type: "snapshot",
    tabs: tabs.map(tabPayload),
    workspaces: uniqueWorkspaces(tabs)
  });
}

async function sendWorkspaceSnapshot() {
  const tabs = await browser.tabs.query({});
  send({
    type: "workspace_snapshot",
    workspaces: uniqueWorkspaces(tabs)
  });
}

async function captureForTab(tabId) {
  const id = Number(tabId);
  if (!Number.isInteger(id)) {
    throw new Error(`Invalid tab id: ${tabId}`);
  }
  try {
    return await browser.tabs.captureTab(id, { format: "jpeg", quality: 60 });
  } catch (_err) {
    const tab = await browser.tabs.get(id);
    return browser.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 60 });
  }
}

function loadImage(dataUrl) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("preview-image-load-failed"));
    img.src = dataUrl;
  });
}

function drawScaledJpeg(img, scale, quality) {
  const width = Math.max(1, Math.round(img.naturalWidth * scale));
  const height = Math.max(1, Math.round(img.naturalHeight * scale));
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d", { alpha: false });
  if (!ctx) {
    throw new Error("preview-canvas-context-unavailable");
  }
  ctx.drawImage(img, 0, 0, width, height);
  return canvas.toDataURL("image/jpeg", quality);
}

async function shrinkPreviewDataUrl(dataUrl) {
  if (messageBytes({ data: dataUrl }) <= PREVIEW_TARGET_BYTES) {
    return dataUrl;
  }
  const img = await loadImage(dataUrl);
  const baseScale = Math.min(
    1,
    PREVIEW_MAX_DIMENSION / Math.max(1, img.naturalWidth, img.naturalHeight)
  );
  let best = dataUrl;
  let bestBytes = messageBytes({ data: dataUrl });
  for (const scaleStep of PREVIEW_SCALE_STEPS) {
    const scale = Math.max(0.1, baseScale * scaleStep);
    for (const quality of PREVIEW_QUALITY_STEPS) {
      const candidate = drawScaledJpeg(img, scale, quality);
      const bytes = messageBytes({ data: candidate });
      if (bytes < bestBytes) {
        best = candidate;
        bestBytes = bytes;
      }
      if (bytes <= PREVIEW_TARGET_BYTES) {
        return candidate;
      }
    }
  }
  return best;
}

async function activateWorkspaceByKey(key) {
  const normalizedKey = String(key || "");
  const tabs = await browser.tabs.query({});
  const target = tabs.find((tab) => workspaceKey(tab) === normalizedKey && !tab.discarded) ||
    tabs.find((tab) => workspaceKey(tab) === normalizedKey);
  if (!target) {
    throw new Error(`Workspace not found: ${normalizedKey}`);
  }
  await browser.windows.update(target.windowId, { focused: true });
  await browser.tabs.update(target.id, { active: true });
}

function parseTabIdFromMessage(message) {
  const fromId = Number(message.tab_id);
  if (Number.isInteger(fromId)) {
    return fromId;
  }
  throw new Error(`Invalid tab_id: ${message.tab_id}`);
}

async function handleOp(message) {
  const op = message.op || "";
  switch (op) {
    case "ping":
      send({ type: "pong" });
      break;
    case "list-tabs":
      await sendSnapshot();
      break;
    case "list-workspaces":
      await sendWorkspaceSnapshot();
      break;
    case "activate-tab":
      {
        const tabId = parseTabIdFromMessage(message);
        let tab = await browser.tabs.get(tabId);
        await browser.windows.update(tab.windowId, { focused: true });
        if (tab.hidden) {
          try {
            await browser.tabs.show(tabId);
            tab = await browser.tabs.get(tabId);
          } catch (err) {
            sendError("activate-tab-show", err?.message || String(err));
          }
        }
        await browser.tabs.update(tabId, { active: true });
        tab = await browser.tabs.get(tabId);
        send({ type: "upsert", tab: tabPayload(tab) });
      }
      break;
    case "close-tab":
      await browser.tabs.remove(parseTabIdFromMessage(message));
      break;
    case "open-url":
      await browser.tabs.create({ url: message.url });
      break;
    case "activate-workspace":
      await activateWorkspaceByKey(message.workspace_id);
      break;
    case "capture-tab": {
      const rawDataUrl = await captureForTab(message.tab_id);
      const imageDataUrl = await shrinkPreviewDataUrl(rawDataUrl);
      send({
        type: "preview",
        tab_id: String(message.tab_id),
        image_data_url: imageDataUrl,
        method: "captureTab+jpeg-shrink"
      });
      break;
    }
    default:
      sendError(op, `Unsupported op: ${op}`);
      break;
  }
}

function onNativeMessage(message) {
  Promise.resolve(handleOp(message)).catch((err) => {
    sendError(message?.op || "", err?.message || String(err));
  });
}

function onNativeDisconnect() {
  nativePort = null;
  scheduleReconnect();
}

function scheduleReconnect() {
  if (nativePort || reconnectTimer) {
    return;
  }
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNative();
  }, RECONNECT_DELAY_MS);
}

function wireTabEvents() {
  browser.tabs.onCreated.addListener((tab) => {
    send({ type: "upsert", tab: tabPayload(tab) });
    send({ type: "workspace-upsert", workspace: workspacePayloadFromTab(tab) });
  });

  browser.tabs.onUpdated.addListener((tabId, _changeInfo, tab) => {
    if (tab && tab.id === tabId) {
      send({ type: "upsert", tab: tabPayload(tab) });
      send({ type: "workspace-upsert", workspace: workspacePayloadFromTab(tab) });
    }
  });

  browser.tabs.onActivated.addListener(async ({ tabId }) => {
    try {
      const tab = await browser.tabs.get(tabId);
      send({ type: "upsert", tab: tabPayload(tab) });
      send({ type: "workspace-upsert", workspace: workspacePayloadFromTab(tab) });
    } catch (err) {
      sendError("tab-activated", err?.message || String(err));
    }
  });

  browser.tabs.onRemoved.addListener((tabId, removeInfo) => {
    send({ type: "remove", key: `zen/default/${tabId}` });
    sendWorkspaceSnapshot().catch((err) => {
      sendError("workspace_snapshot", err?.message || String(err));
    });
  });
}

function connectNative() {
  try {
    nativePort = browser.runtime.connectNative(HOST_NAME);
    nativePort.onMessage.addListener(onNativeMessage);
    nativePort.onDisconnect.addListener(onNativeDisconnect);
    sendSnapshot().catch((err) => {
      sendError("list-tabs", err?.message || String(err));
    });
    sendWorkspaceSnapshot().catch((err) => {
      sendError("list-workspaces", err?.message || String(err));
    });
  } catch (err) {
    nativePort = null;
    sendError("connect-native", err?.message || String(err));
    scheduleReconnect();
  }
}

wireTabEvents();
connectNative();
