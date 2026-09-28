// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-FileCopyrightText: Slovensko.Digital and contributors to autogram-extension
// SPDX-License-Identifier: EUPL-1.2

// D.Signer / D.Bridge JS surface.
//
// State portals drive signing through `window.ditec`. This file owns that object
// and translates the calls into one request for Chevron7.
//
// Ported from slovensko-digital/autogram-extension (EUPL-1.2), which is the
// reference for what the portals actually call. Written in plain JavaScript so
// the extension needs no build step.
//
// The call order the portals use is worth knowing: `addXmlObject` stores the
// document, `sign` only records the signature parameters and returns at once,
// and the *getter* afterwards is what actually signs and hands back the result.

(function () {
  "use strict";

  var CHANNEL_REQUEST = "chevron7-request";
  var CHANNEL_RESPONSE = "chevron7-response";
  var XDC_XMLNS = "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1";

  var counter = 0;
  var pending = new Map();

  window.addEventListener(CHANNEL_RESPONSE, function (event) {
    var detail = event.detail || {};
    var resolve = pending.get(detail.id);
    if (!resolve) return;
    pending.delete(detail.id);
    resolve(detail.reply);
  });

  function call(kind, request) {
    var id = "chevron7-" + Date.now() + "-" + counter++;
    return new Promise(function (resolve) {
      pending.set(id, resolve);
      window.dispatchEvent(new CustomEvent(CHANNEL_REQUEST, {
        detail: { id: id, kind: kind, request: request }
      }));
    });
  }

  function toBase64(text) {
    return btoa(unescape(encodeURIComponent(text)));
  }

  function fromBase64(text) {
    try {
      return decodeURIComponent(escape(atob(text)));
    } catch (e) {
      // Not base64 after all; the portals are not consistent about this.
      return text;
    }
  }

  /// The portal's objectId often already carries an extension, for instance
  /// "Vseobecna_agenda.xdcf". The payload is the form XML, and the engine names
  /// the container it builds after the source, so the source must be named .xml
  /// or the container ends up as "Vseobecna_agenda.xdcf.xdcf".
  function xmlSourceName(objectId) {
    var base = String(objectId || "formular");
    // Only known extensions, never the last dot: an objectId like
    // "App.GeneralAgenda" is a name, not a file with a ".GeneralAgenda" suffix.
    base = base.replace(/\.(xdcf|xml)$/i, "");
    return base + ".xml";
  }

  /// Same rule for plain documents: the app and the engine read the payload
  /// type from the filename extension, so a TXT/PNG source must keep one.
  function plainSourceName(objectId, fallback, extension) {
    var base = String(objectId || fallback);
    base = base.replace(/\.(txt|png)$/i, "");
    return base + extension;
  }

  function emptyToNull(value) {
    return value === undefined || value === null || value === "" ? null : value;
  }

  // MARK: signing session

  var session = {
    object: null,
    signatureId: null,
    digestAlgUri: null,
    signaturePolicyIdentifier: null,
    signed: null
  };

  function reset() {
    session.object = null;
    session.signed = null;
  }

  /**
   * Turns the stored ditec object into the request the app understands.
   *
   * Schema and transformation are handed over decoded: the app base64 encodes
   * them again on the way to the engine, which is where that encoding belongs.
   */
  function buildRequest(overrides) {
    var object = session.object;
    if (!object) throw new Error("Nie je pripravený žiadny dokument na podpis.");
    var options = overrides || {};
    var level = options.level || "XAdES_BASELINE_B";

    if (object.type === "XadesPdf" || object.type === "XadesBpPdf") {
      // getSignatureWithASiCEnvelopeBase64 expects XAdES in an ASiC-E container
      // around the PDF, exactly as upstream autogram-extension sends it. Without
      // the container the phone relay rejects the request and a card signature
      // comes back as a PAdES PDF the portal cannot use.
      var pdfRequest = {
        requestID: session.signatureId || ("ditec-" + Date.now()),
        filename: (function (id) {
          var name = String(id || "dokument");
          return /\.pdf$/i.test(name) ? name : name + ".pdf";
        })(object.objectId),
        content: object.sourcePdfBase64,
        payloadMimeType: "application/pdf;base64",
        signatureLevel: options.level || "PAdES_BASELINE_B"
      };
      if (options.container) {
        pdfRequest.container = options.container;
      }
      return pdfRequest;
    }

    // Plain text and images travel without eform attributes, exactly as
    // upstream autogram-extension sends them: the payload mime tells the
    // engine what they are, the ASiC-E container carries the signature.
    if (object.type === "XadesBpTxt") {
      return {
        requestID: session.signatureId || ("ditec-" + Date.now()),
        filename: plainSourceName(object.objectId, "dokument", ".txt"),
        content: toBase64(object.sourceTxt),
        payloadMimeType: "text/plain;base64",
        signatureLevel: level,
        container: options.container || "ASiC_E"
      };
    }

    if (object.type === "XadesBpPng" || object.type === "XadesPng") {
      return {
        requestID: session.signatureId || ("ditec-" + Date.now()),
        filename: plainSourceName(object.objectId, "obrazok", ".png"),
        content: object.sourcePngBase64,
        payloadMimeType: "image/png;base64",
        signatureLevel: level,
        container: options.container || "ASiC_E"
      };
    }

    var isXdc = object.type === "XadesBpXml" || object.type === "XadesXml"
      || object.type === "XadesBp2Xml" || object.type === "Xades2Xml";
    if (!isXdc) {
      throw new Error("Typ objektu " + object.type + " zatiaľ nie je podporovaný.");
    }

    var xml, schema, transformation, identifier;
    if (object.type === "XadesBpXml") {
      xml = object.xdcXMLData;
      schema = fromBase64(object.xdcUsedXSD);
      transformation = fromBase64(object.xdcUsedXSLT);
      identifier = object.xdcIdentifier && object.xdcIdentifier.indexOf("/") !== -1
        ? object.xdcIdentifier
        : object.xdcIdentifier + "/" + object.xdcVersion;
    } else if (object.type === "XadesBp2Xml") {
      xml = object.sourceXml;
      schema = object.sourceXsd;
      transformation = object.sourceXsl;
      identifier = object.namespaceUri;
    } else {
      xml = object.sourceXml;
      schema = object.sourceXsd;
      transformation = object.sourceXsl;
      identifier = object.namespaceUri;
    }

    return {
      requestID: session.signatureId || ("ditec-" + Date.now()),
      filename: xmlSourceName(object.objectId),
      content: toBase64(xml),
      payloadMimeType: "application/xml;base64",
      signatureLevel: level,
      container: options.container || "ASiC_E",
      eform: {
        containerXmlns: XDC_XMLNS,
        schema: schema,
        transformation: transformation,
        identifier: identifier,
        schemaIdentifier: emptyToNull(object.xsdReferenceURI),
        transformationIdentifier: emptyToNull(object.xslReferenceURI),
        transformationLanguage: emptyToNull(object.xslXSLTLanguage),
        transformationMediaDestinationTypeDescription:
          emptyToNull(object.xslMediaDestinationTypeDescription),
        transformationTargetEnvironment: emptyToNull(object.xslTargetEnvironment),
        // Upstream autogram-extension sends embedUsedSchemas = !includeRefs;
        // FS passes xdcIncludeRefs=true and expects schemas referenced, not embedded.
        embedUsedSchemas: object.xdcIncludeRefs !== true,
        autoLoadEform: false,
        fsFormID: null,
        packaging: "ENVELOPING"
      }
    };
  }

  function performSignature(overrides, callback) {
    var request;
    try {
      request = buildRequest(overrides);
    } catch (error) {
      if (callback && callback.onError) callback.onError(error.message);
      return;
    }

    function fail(message) {
      if (callback && callback.onError) callback.onError(message);
    }

    function deliver(responseText) {
      var parsed;
      try {
        parsed = JSON.parse(responseText);
      } catch (error) {
        fail("Odpoveď sa nepodarilo prečítať.");
        return;
      }
      session.signed = parsed;
      if (callback && callback.onSuccess) callback.onSuccess(parsed.content);
    }

    // Safari ends the extension's background after about 30 seconds and then
    // answers with undefined, while a signature waits for a PIN or a phone much
    // longer. So the request only starts a job, and the result is collected with
    // short messages. A missing reply is the background restarting, not a failure.
    var MISSING_REPLY_LIMIT = 40;
    var POLL_INTERVAL_MS = 1500;
    var missingReplies = 0;

    function poll(jobID) {
      call("sign-result", jobID).then(function (reply) {
        if (!reply) {
          missingReplies += 1;
          if (missingReplies > MISSING_REPLY_LIMIT) {
            fail("Spojenie s aplikáciou Chevron7 sa prerušilo. Skúste podpísať znova.");
            return;
          }
          setTimeout(function () { poll(jobID); }, POLL_INTERVAL_MS);
          return;
        }
        missingReplies = 0;
        if (reply.done !== true) {
          if (reply.ok !== true) {
            fail(reply.error || "Podpisovanie zlyhalo.");
            return;
          }
          setTimeout(function () { poll(jobID); }, POLL_INTERVAL_MS);
          return;
        }
        if (reply.ok !== true) {
          fail(reply.error || "Podpisovanie zlyhalo.");
          return;
        }
        deliver(reply.response);
      });
    }

    function begin() {
      call("sign-begin", JSON.stringify(request)).then(function (reply) {
        if (!reply) {
          missingReplies += 1;
          if (missingReplies > MISSING_REPLY_LIMIT) {
            fail("Chevron7 neodpovedal. Skontrolujte, či je rozšírenie zapnuté.");
            return;
          }
          setTimeout(begin, POLL_INTERVAL_MS);
          return;
        }
        missingReplies = 0;
        if (reply.ok !== true || !reply.jobID) {
          fail(reply.error || "Podpisovanie zlyhalo.");
          return;
        }
        poll(reply.jobID);
      });
    }

    begin();
  }

  // MARK: adapters

  function DSigAdapter() {}
  DSigAdapter.prototype = {
    _ready: true,
    SHA1: "http://www.w3.org/2000/09/xmldsig#sha1",
    SHA256: "http://www.w3.org/2001/04/xmlenc#sha256",
    SHA384: "http://www.w3.org/2001/04/xmldsig-more#sha384",
    SHA512: "http://www.w3.org/2001/04/xmlenc#sha512",
    LANG_SK: "SK",
    LANG_EN: "EN",
    XML_VISUAL_TRANSFORM_TXT: "TXT",
    XML_VISUAL_TRANSFORM_HTML: "HTML",
    PDF_CONFORMANCE_LEVEL_1A: 0,
    PDF_CONFORMANCE_LEVEL_1B: 1,
    PDF_CONFORMANCE_LEVEL_NONE: 2,
    ERROR_SIGNING_CANCELLED: 1,

    initialize: function (callback) {
      call("status", null).then(function (reply) {
        if (reply && reply.ok) {
          if (callback && callback.onSuccess) callback.onSuccess();
        } else if (callback && callback.onError) {
          callback.onError((reply && reply.error) || "Chevron7 nie je dostupný.");
        }
      });
    },

    // Records the parameters only. The portals sign by calling a getter next,
    // which is where the request actually leaves the page.
    sign: function (signatureId, digestAlgUri, signaturePolicyIdentifier, callback) {
      session.signatureId = signatureId;
      session.digestAlgUri = digestAlgUri;
      session.signaturePolicyIdentifier = signaturePolicyIdentifier;
      if (callback && callback.onSuccess) callback.onSuccess();
    },

    setLanguage: function (language, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    getVersion: function (callback) {
      if (callback && callback.onSuccess) callback.onSuccess("1.0.0");
    },
    getSignerIdentification: function (callback) {
      if (callback && callback.onSuccess) {
        callback.onSuccess(session.signed ? session.signed.signedBy : "");
      }
    },
    detectSupportedPlatforms: function (platforms, callback) {
      if (callback && callback.onSuccess) callback.onSuccess(["java"]);
    },
    deploy: function (options, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    checkPDFACompliance: function (pdf, password, level, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    convertToPDFA: function (pdf, password, level, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    setWindowSize: function (width, height, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    setCertificateFilter: function (filter, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    setSigningTimeProcessing: function (displayGui, includeSigningTime, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    }
  };

  function storeObject(object, callback) {
    if (session.signed) reset();
    session.object = object;
    if (callback && callback.onSuccess) callback.onSuccess();
  }

  function DSigXadesBpAdapter() {}
  DSigXadesBpAdapter.prototype = Object.create(DSigAdapter.prototype);

  DSigXadesBpAdapter.prototype.addXmlObject = function (
    objectId, objectDescription, objectFormatIdentifier, xdcXMLData, xdcIdentifier,
    xdcVersion, xdcUsedXSD, xsdReferenceURI, xdcUsedXSLT, xslReferenceURI,
    xslMediaDestinationTypeDescription, xslXSLTLanguage, xslTargetEnvironment,
    xdcIncludeRefs, xdcNamespaceURI, callback
  ) {
    storeObject({
      type: "XadesBpXml",
      objectId: objectId,
      objectDescription: objectDescription,
      objectFormatIdentifier: objectFormatIdentifier,
      xdcXMLData: xdcXMLData,
      xdcIdentifier: xdcIdentifier,
      xdcVersion: xdcVersion,
      xdcUsedXSD: xdcUsedXSD,
      xsdReferenceURI: xsdReferenceURI,
      xdcUsedXSLT: xdcUsedXSLT,
      xslReferenceURI: xslReferenceURI,
      xslMediaDestinationTypeDescription: xslMediaDestinationTypeDescription,
      xslXSLTLanguage: xslXSLTLanguage,
      xslTargetEnvironment: xslTargetEnvironment,
      xdcIncludeRefs: xdcIncludeRefs,
      xdcNamespaceURI: xdcNamespaceURI
    }, callback);
  };

  DSigXadesBpAdapter.prototype.addXmlObject2 = function (
    objectId, objectDescription, namespaceUri, sourceXml, sourceXsd, sourceXsl, callback
  ) {
    storeObject({
      type: "XadesBp2Xml",
      objectId: objectId,
      objectDescription: objectDescription,
      namespaceUri: namespaceUri,
      sourceXml: sourceXml,
      sourceXsd: sourceXsd,
      sourceXsl: sourceXsl
    }, callback);
  };

  DSigXadesBpAdapter.prototype.addPdfObject = function (
    objectId, objectDescription, sourcePdfBase64, password, objectFormatIdentifier,
    reqLevel, convert, callback
  ) {
    storeObject({
      type: "XadesBpPdf",
      objectId: objectId,
      objectDescription: objectDescription,
      sourcePdfBase64: sourcePdfBase64,
      password: password,
      objectFormatIdentifier: objectFormatIdentifier,
      reqLevel: reqLevel,
      convert: convert
    }, callback);
  };

  // Ported from upstream autogram-extension: plain text and images are stored
  // with their own types and signed through the same ASiC getter as a PDF.
  DSigXadesBpAdapter.prototype.addTxtObject = function (
    objectId, objectDescription, sourceTxt, objectFormatIdentifier, callback
  ) {
    storeObject({
      type: "XadesBpTxt",
      objectId: objectId,
      objectDescription: objectDescription,
      sourceTxt: sourceTxt,
      objectFormatIdentifier: objectFormatIdentifier
    }, callback);
  };

  DSigXadesBpAdapter.prototype.addPngObject = function (
    objectId, objectDescription, sourcePngBase64, objectFormatIdentifier, callback
  ) {
    storeObject({
      type: "XadesBpPng",
      objectId: objectId,
      objectDescription: objectDescription,
      sourcePngBase64: sourcePngBase64,
      objectFormatIdentifier: objectFormatIdentifier
    }, callback);
  };

  DSigXadesBpAdapter.prototype.getConvertedPDFA = function (callback) {
    // Upstream answers with the original object; conversion itself is a no-op.
    var object = session.object;
    var original = object && (object.sourcePdfBase64 || object.sourcePngBase64
      || object.xdcXMLData || object.sourceXml || object.sourceTxt);
    if (original != null) {
      if (callback && callback.onSuccess) callback.onSuccess(original);
    } else if (callback && callback.onError) {
      callback.onError("Nie je pripravený žiadny dokument.");
    }
  };

  DSigXadesBpAdapter.prototype.getSignatureWithASiCEnvelopeBase64 = function (callback) {
    performSignature({ container: "ASiC_E", packaging: "ENVELOPING", level: "XAdES_BASELINE_B" }, callback);
  };

  function DSigXadesAdapter() {}
  DSigXadesAdapter.prototype = Object.create(DSigAdapter.prototype);

  DSigXadesAdapter.prototype.addXmlObject = function (
    objectId, objectDescription, sourceXml, sourceXsd, namespaceUri,
    xsdReference, sourceXsl, xslReference, callback
  ) {
    storeObject({
      type: "XadesXml",
      objectId: objectId,
      objectDescription: objectDescription,
      sourceXml: sourceXml,
      sourceXsd: sourceXsd,
      namespaceUri: namespaceUri,
      xsdReference: xsdReference,
      sourceXsl: sourceXsl,
      xslReference: xslReference
    }, callback);
  };

  // Ported from upstream autogram-extension, same signatures including the
  // trailing transformType. Types match upstream exactly: Xades2Xml for the
  // second XML form, XadesBpTxt for text, XadesPng for images.
  DSigXadesAdapter.prototype.addXmlObject2 = function (
    objectId, objectDescription, sourceXml, sourceXsd, namespaceUri,
    xsdReference, sourceXsl, xslReference, transformType, callback
  ) {
    storeObject({
      type: "Xades2Xml",
      objectId: objectId,
      objectDescription: objectDescription,
      sourceXml: sourceXml,
      sourceXsd: sourceXsd,
      namespaceUri: namespaceUri,
      xsdReference: xsdReference,
      sourceXsl: sourceXsl,
      xslReference: xslReference,
      transformType: transformType
    }, callback);
  };

  DSigXadesAdapter.prototype.addTxtObject = function (
    objectId, objectDescription, sourceTxt, objectFormatIdentifier, callback
  ) {
    storeObject({
      type: "XadesBpTxt",
      objectId: objectId,
      objectDescription: objectDescription,
      sourceTxt: sourceTxt,
      objectFormatIdentifier: objectFormatIdentifier
    }, callback);
  };

  DSigXadesAdapter.prototype.addPngObject = function (
    objectId, objectDescription, sourcePngBase64, objectFormatIdentifier, callback
  ) {
    storeObject({
      type: "XadesPng",
      objectId: objectId,
      objectDescription: objectDescription,
      sourcePngBase64: sourcePngBase64,
      objectFormatIdentifier: objectFormatIdentifier
    }, callback);
  };

  // Old D.Signer calls upstream only stubs out; a missing method would throw
  // a TypeError on the page instead.
  DSigXadesAdapter.prototype.sign11 = function (
    signatureId, digestAlgUri, signaturePolicyIdentifier, dataEnvelopeId,
    dataEnvelopeURI, dataEnvelopeDescr, callback
  ) {
    if (typeof console !== "undefined" && console.warn) {
      console.warn("sign11 is not supported, treating as sign.");
    }
    if (callback && callback.onSuccess) callback.onSuccess();
  };

  DSigXadesAdapter.prototype.sign20 = function (
    signatureId, digestAlgUri, signaturePolicyIdentifier, dataEnvelopeId,
    dataEnvelopeURI, dataEnvelopeDescr, callback
  ) {
    if (typeof console !== "undefined" && console.warn) {
      console.warn("sign20 is not supported, treating as sign.");
    }
    if (callback && callback.onSuccess) callback.onSuccess();
  };

  DSigXadesAdapter.prototype.addPdfObject = DSigXadesBpAdapter.prototype.addPdfObject;
  DSigXadesAdapter.prototype.getConvertedPDFA = DSigXadesBpAdapter.prototype.getConvertedPDFA;

  DSigXadesAdapter.prototype.getSignedXmlWithEnvelope = function (callback) {
    performSignature({ level: "XAdES_BASELINE_B" }, callback);
  };

  DSigXadesAdapter.prototype.getSignedXmlWithEnvelopeAndTimeStamp = function (callback) {
    performSignature({ level: "XAdES_BASELINE_T" }, callback);
  };

  DSigXadesAdapter.prototype.getSigningCertificate = function (callback) {
    if (callback && callback.onSuccess) {
      callback.onSuccess(session.signed ? session.signed.issuedBy : "");
    }
  };

  DSigXadesAdapter.prototype.getSigningTime = function (callback) {
    if (callback && callback.onSuccess) callback.onSuccess(new Date().toISOString());
  };

  // MARK: the object the portals reach for

  var ditec = {
    isAutogram: true,
    isChevron7: true,
    config: { downloadPage: { url: "", title: "" } },
    utils: {
      ERROR_CANCELLED: 1,
      ERROR_GENERAL: -200,
      ERROR_NOT_INSTALLED: -201,
      ERROR_LAUNCH_FAILED: -202,
      ERROR_LAUNCH_FORBIDDEN: -203,
      isDitecError: function () { return true; },
      extendClass: function () {}
    },
    versions: {},
    dSigXadesJs: new DSigXadesAdapter(),
    dSigXadesBpJs: new DSigXadesBpAdapter()
  };

  try {
    Object.defineProperty(window, "ditec", {
      value: ditec,
      writable: false,
      configurable: false
    });
  } catch (error) {
    window.ditec = ditec;
  }
})();
