// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

// Content script. Injects the page-context shim and relays its requests to the
// background worker, which is the only caller of native messaging.
//
// Safari injects content scripts again into pages that are already open when the
// extension is reloaded, for instance after Chevron7 is reinstalled. A second copy
// in the same isolated world failed on its `const` declarations, so the whole
// script runs once per frame.
(() => {
if (globalThis.__chevron7ContentScript) {
  return;
}
globalThis.__chevron7ContentScript = true;

console.log("[Chevron7] content script beží na", location.href);

const CHANNEL_REQUEST = "chevron7-request";
const CHANNEL_RESPONSE = "chevron7-response";

// The per-site switch. The popup stores it in browser.storage, which is async,
// but the choice has to be made before ditec.js defines window.ditec: that
// property is non-configurable, so a portal's own D.Signer (or D.Bridge 2) can
// never replace it later. A copy of the flag therefore lives in the page
// origin's localStorage, which this script can read synchronously at
// document_start. The page can edit that copy, but the most it gains is opting
// itself out; signing requests are checked against browser.storage below.
const STORAGE_KEY = "siteDisabled:" + location.host;
const MIRROR_KEY = "chevron7.siteDisabled";

function readMirror() {
  try {
    return window.localStorage.getItem(MIRROR_KEY) === "true";
  } catch (error) {
    // Sandboxed frames have no localStorage. Treat them as enabled.
    return false;
  }
}

function writeMirror(disabled) {
  try {
    if (disabled) {
      window.localStorage.setItem(MIRROR_KEY, "true");
    } else {
      window.localStorage.removeItem(MIRROR_KEY);
    }
  } catch (error) {
    console.warn("[Chevron7] nastavenie stránky sa nepodarilo uložiť do localStorage", error);
  }
}

const disabledAtLoad = readMirror();

if (disabledAtLoad) {
  console.log("[Chevron7] na tejto stránke vypnuté, ponechávam pôvodný D.Signer");
} else {
  // ditec.js must land before the page script runs, so it is injected first and
  // synchronously; inject.js only adds the direct window.chevron7 surface.
  for (const file of ["ditec.js", "inject.js"]) {
    const script = document.createElement("script");
    script.src = browser.runtime.getURL(file);
    script.async = false;
    (document.head || document.documentElement).appendChild(script);
    script.remove();
  }
  pinComposerSigningMethod();
}

// The nove.slovensko.sk message composer keeps its signing method in the page's
// localStorage and reads it once while booting. Its own "Autogram" method calls
// http://localhost:37200 directly, which Chevron7 never serves, so a person who
// once picked it could not sign. "Dsigner" goes through window.ditec, which is
// ours. Set on every load, before the composer's bundle runs (as upstream
// autogram-extension does in fixed-signer.ts).
function pinComposerSigningMethod() {
  if (location.hostname !== "message-constructor-web.slovensko.sk") return;
  try {
    window.localStorage.setItem("signer-type", "Dsigner");
  } catch (error) {
    console.warn("[Chevron7] spôsob podpisovania v skladači správ sa nepodarilo nastaviť", error);
  }
}

// browser.storage is the authority. It brings the copy up to date for the next
// load, for instance after the page's site data was cleared.
const siteDisabled = (async () => {
  try {
    const stored = await browser.storage.local.get(STORAGE_KEY);
    const disabled = stored && stored[STORAGE_KEY] === true;
    if (disabled !== disabledAtLoad) {
      writeMirror(disabled);
      console.log("[Chevron7] nastavenie stránky sa zmenilo, prejaví sa po obnovení stránky");
    }
    return disabled;
  } catch (error) {
    console.error("[Chevron7] nepodarilo sa načítať nastavenie stránky", error);
    return disabledAtLoad;
  }
})();

// The popup updates the copy before it reloads the tab, so the reload already
// makes the new choice. Every frame of the tab gets the message; only frames on
// the host the popup switched act on it.
browser.runtime.onMessage.addListener((message) => {
  if (message?.kind !== "site-enabled-changed") return;
  if (message.host !== location.host) return;
  writeMirror(message.enabled !== true);
  return Promise.resolve({ ok: true });
});

window.addEventListener(CHANNEL_REQUEST, async (event) => {
  const detail = event.detail || {};
  // A page on a switched-off site can still reach this channel, for instance
  // after it removed the localStorage copy. It gets no new signature.
  if ((detail.kind === "sign" || detail.kind === "sign-begin") && await siteDisabled) {
    window.dispatchEvent(new CustomEvent(CHANNEL_RESPONSE, {
      detail: {
        id: detail.id,
        reply: { ok: false, error: "Chevron7 je na tejto stránke vypnutý. Obnovte stránku." }
      }
    }));
    return;
  }
  // Safari may have ended the background worker, which rejects the message or
  // answers undefined. The page always gets an answer so it can retry.
  // The page builds the request, so it could claim any origin. The host is set
  // here from the content script's own location, overwriting whatever it sent.
  let request = detail.request;
  if ((detail.kind === "sign" || detail.kind === "sign-begin") && typeof request === "string") {
    try {
      const parsed = JSON.parse(request);
      parsed.pageHost = location.hostname;
      request = JSON.stringify(parsed);
    } catch (error) {
      console.warn("[Chevron7] požiadavku na podpis sa nepodarilo doplniť o adresu stránky", error);
    }
  }
  let reply;
  try {
    reply = await browser.runtime.sendMessage({
      kind: detail.kind,
      request: request
    });
  } catch (error) {
    console.warn("[Chevron7] správa pre pozadie rozšírenia zlyhala", error);
    reply = undefined;
  }
  window.dispatchEvent(new CustomEvent(CHANNEL_RESPONSE, {
    detail: { id: detail.id, reply }
  }));
});

})();
