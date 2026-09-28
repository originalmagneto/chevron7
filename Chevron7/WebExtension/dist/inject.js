// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-FileCopyrightText: Slovensko.Digital and contributors to autogram-extension
// SPDX-License-Identifier: EUPL-1.2

// Page-context shim.
//
// State portals drive signing through the Ditec D.Signer object at
// `window.ditec`. This file owns that surface and forwards to the content
// script, which reaches the app through the background worker.
//
// Scope note: the D.Signer surface lives in ditec.js (dSigXadesJs and
// dSigXadesBpJs with the per-filetype strategies, ported from the upstream
// EUPL-1.2 implementations in slovensko-digital/autogram-extension under
// src/dbridge_js/ditecx). What is here is the transport and the object shape.

(function () {
  const CHANNEL_REQUEST = "chevron7-request";
  const CHANNEL_RESPONSE = "chevron7-response";

  let counter = 0;
  const pending = new Map();

  window.addEventListener(CHANNEL_RESPONSE, (event) => {
    const { id, reply } = event.detail || {};
    const resolve = pending.get(id);
    if (!resolve) return;
    pending.delete(id);
    resolve(reply);
  });

  function call(kind, request) {
    const id = `chevron7-${Date.now()}-${counter++}`;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      window.dispatchEvent(new CustomEvent(CHANNEL_REQUEST, {
        detail: { id, kind, request }
      }));
    });
  }

  const chevron7 = {
    isChevron7: true,

    /** Whether Chevron7 is running and ready to sign. */
    async status() {
      return call("status", null);
    },

    /**
     * Signs one document.
     *
     * `request` matches WebSignRequest in the app: requestID, filename,
     * content (base64), payloadMimeType, signatureLevel and optional eform.
     */
    async sign(request) {
      return call("sign", JSON.stringify(request));
    }
  };

  // Exposed for the spike and for pages that integrate directly rather than
  // through the D.Signer surface.
  Object.defineProperty(window, "chevron7", {
    value: Object.freeze(chevron7),
    writable: false,
    configurable: false
  });
})();
