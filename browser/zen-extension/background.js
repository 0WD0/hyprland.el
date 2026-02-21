"use strict";

const HOST_NAME = "hyprland_zen_bridge";
const ENABLE_CONSOLE_FALLBACK = true;

let nativePort = null;

function workspaceKey(tab) {
  const container = tab.cookieStoreId || "default";
  return `win:${tab.windowId}|container:${container}`;
}

function workspacePayloadFromTab(tab) {
  return {
    browser: "zen",
    profile: "default",
    workspace_id: workspaceKey(tab),
    name: workspaceKey(tab),
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
    workspace_name: workspaceKey(tab),
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
    if (ENABLE_CONSOLE_FALLBACK) {
      console.debug("[hyprland-zen-extension]", message);
    }
    return;
  }
  try {
    nativePort.postMessage(message);
  } catch (_err) {
    if (ENABLE_CONSOLE_FALLBACK) {
      console.debug("[hyprland-zen-extension]", message);
    }
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

async function activateWorkspaceByKey(key) {
  const tabs = await browser.tabs.query({});
  const target = tabs.find((tab) => workspaceKey(tab) === key && !tab.discarded) ||
    tabs.find((tab) => workspaceKey(tab) === key);
  if (!target) {
    throw new Error(`Workspace not found: ${key}`);
  }
  await browser.windows.update(target.windowId, { focused: true });
  await browser.tabs.update(target.id, { active: true });
}

function parseTabIdFromMessage(message) {
  const fromId = Number(message.tab_id);
  if (Number.isInteger(fromId)) {
    return fromId;
  }
  const key = String(message.key || "");
  const raw = key.split("/").pop();
  const parsed = Number(raw);
  if (Number.isInteger(parsed)) {
    return parsed;
  }
  throw new Error(`Invalid tab key/tab_id: ${key || message.tab_id}`);
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
      await activateWorkspaceByKey(message.key);
      break;
    case "capture-tab": {
      const imageDataUrl = await captureForTab(message.tab_id);
      send({
        type: "preview",
        tab_id: String(message.tab_id),
        image_data_url: imageDataUrl,
        method: "captureTab"
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
    const tab = await browser.tabs.get(tabId);
    send({ type: "upsert", tab: tabPayload(tab) });
    send({ type: "workspace-upsert", workspace: workspacePayloadFromTab(tab) });
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
  } catch (err) {
    nativePort = null;
    sendError("connect-native", err?.message || String(err));
  }
}

wireTabEvents();
connectNative();
