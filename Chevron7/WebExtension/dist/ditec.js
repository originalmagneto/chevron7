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

  // D.Bridge error codes (ditec.utils.ERROR_*). Portals branch on them: code 1
  // is a cancellation they ignore, any other code they show or rethrow.
  var ERROR_CANCELLED = 1;
  var ERROR_GENERAL = -200;

  /**
   * What `onError` must receive. The portals check `e.name === "DitecError"`
   * and otherwise rethrow, so a plain string never reached the person, and
   * they silence `code === 1` only inside that branch. ERROR_GENERAL makes
   * them fall back to our message instead of their own D.Signer text.
   */
  function createDitecError(code, message) {
    var error = new Error(message);
    error.name = "DitecError";
    error.code = code;
    error.toString = function () {
      return error.name + "(" + error.code + ") " + error.message;
    };
    return error;
  }

  function generalError(message) {
    return createDitecError(ERROR_GENERAL, message);
  }

  function unsupported(name, callback) {
    if (callback && callback.onError) {
      callback.onError(generalError("Funkcia " + name + " nie je podporovaná rozšírením Chevron7."));
    }
  }

  /**
   * Reported by getVersion. A compatibility gate, not decoration:
   * schranka.slovensko.sk and nove.slovensko.sk parse it as JSON and require
   * the XmlBpPlugin at 2.0.0.13 or later before they call addXmlObject2.
   * Value from slovensko-digital/autogram-extension (dsigner-version.ts).
   */
  var DSIGNER_VERSION_JSON = '{"name":"D.Signer/XAdES BP Java","version":"2.0.0.23","plugins":['
    + '{"name":"sk.ditec.zep.dsigner.xades.bp.plugins.xmlplugin.XmlBpPlugin","version":"2.0.0.23"},'
    + '{"name":"sk.ditec.zep.dsigner.xades.bp.plugins.txtplugin.TxtBpPlugin","version":"2.0.0.23"},'
    + '{"name":"sk.ditec.zep.dsigner.xades.bp.plugins.pngplugin.PngBpPlugin","version":"2.0.0.23"},'
    + '{"name":"sk.ditec.zep.dsigner.xades.bp.plugins.pdfplugin.PdfBpPlugin","version":"2.0.0.23"}]}';

  /// Shown by getSignerIdentification before a signature exists: PFS asks for
  /// the name first and parses whatever follows "CN=".
  var SIGNER_PLACEHOLDER = "CN=(Používateľ Chevron7)";

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

  /// A ready-made XML Data Container keeps a single .xdcf: the engine reads the
  /// payload type from the extension and signs an .xdcf source as it is.
  function xdcSourceName(objectId) {
    var base = String(objectId || "formular");
    base = base.replace(/\.(xdcf|xml)$/i, "");
    return base + ".xdcf";
  }

  /// Same rule for plain documents: the app and the engine read the payload
  /// type from the filename extension, so a TXT/PNG source must keep one.
  function plainSourceName(objectId, fallback, extension) {
    var base = String(objectId || fallback);
    base = base.replace(/\.(txt|png)$/i, "");
    return base + extension;
  }

  /// The canonical form identifier ends with the form version. PFS passes the
  /// namespace URI without it, so a check for any "/" kept it unversioned; the
  /// version is appended unless it is already the last segment (as upstream
  /// autogram-extension and the PFS bundle itself derive it).
  function formIdentifierWithVersion(identifier, version) {
    if (!identifier) return identifier;
    if (!version || String(identifier).split("/").pop() === String(version)) return identifier;
    return identifier + "/" + version;
  }

  function emptyToNull(value) {
    return value === undefined || value === null || value === "" ? null : value;
  }

  // MARK: signing session

  var session = {
    objects: [],
    signatureId: null,
    digestAlgUri: null,
    signaturePolicyIdentifier: null,
    signed: null
  };

  function reset() {
    session.objects = [];
    session.signed = null;
  }

  var PDF_MIME = "application/pdf;base64";
  var XDC_MIME = "application/vnd.gov.sk.xmldatacontainer+xml;base64";

  /**
   * A stored object that is signed as the file it is: PDF, plain text, image or
   * a ready-made XML Data Container. Null for a form the engine still has to
   * build into a container from its XML.
   */
  function fileObject(object) {
    if (object.type === "XadesPdf" || object.type === "XadesBpPdf") {
      return {
        filename: (function (id) {
          var name = String(id || "dokument");
          return /\.pdf$/i.test(name) ? name : name + ".pdf";
        })(object.objectId),
        content: object.sourcePdfBase64,
        payloadMimeType: PDF_MIME
      };
    }
    // Plain text and images travel without eform attributes, exactly as
    // upstream autogram-extension sends them: the payload mime tells the
    // engine what they are, the ASiC-E container carries the signature.
    if (object.type === "XadesBpTxt") {
      return {
        filename: plainSourceName(object.objectId, "dokument", ".txt"),
        content: toBase64(object.sourceTxt),
        payloadMimeType: "text/plain;base64"
      };
    }
    if (object.type === "XadesBpPng" || object.type === "XadesPng") {
      return {
        filename: plainSourceName(object.objectId, "obrazok", ".png"),
        content: object.sourcePngBase64,
        payloadMimeType: "image/png;base64"
      };
    }
    // schranka and nove hand a finished container in base64; it is signed as
    // it is, never wrapped again (upstream: XadesBp2XmlStrategy).
    if (object.type === "XadesBp2Xml") {
      return {
        filename: xdcSourceName(object.objectId),
        content: object.xdcXDCB64,
        payloadMimeType: XDC_MIME
      };
    }
    return null;
  }

  function newRequestID() {
    return session.signatureId || ("ditec-" + Date.now());
  }

  /**
   * Turns the stored ditec objects into the request the app understands.
   *
   * Schema and transformation are handed over decoded: the app base64 encodes
   * them again on the way to the engine, which is where that encoding belongs.
   */
  function buildRequest(overrides) {
    var objects = session.objects;
    if (objects.length === 0) throw new Error("Nie je pripravený žiadny dokument na podpis.");
    var options = overrides || {};
    return objects.length === 1
      ? buildSingleRequest(objects[0], options)
      : buildMultiRequest(objects, options);
  }

  /**
   * Several documents added before one signature, as schranka chains them: one
   * ASiC-E whose XAdES signature covers each of them as a data object, which is
   * what D.Signer returns from getSignatureWithASiCEnvelopeBase64. The engine
   * signs further data objects only next to a PDF, so a PDF carries the request
   * and the others follow in the portal's order.
   */
  function buildMultiRequest(objects, options) {
    if (options.container !== "ASiC_E") {
      throw new Error("Viac dokumentov v jednej obálke XAdES Chevron7 zatiaľ nepodpisuje. "
        + "Podpíšte dokumenty jednotlivo, alebo použite aplikáciu D.Signer.");
    }
    var files = objects.map(function (object) {
      var file = fileObject(object);
      if (!file) {
        throw new Error("Elektronický formulár spolu s ďalšími dokumentmi Chevron7 zatiaľ nepodpisuje. "
          + "Podpíšte ho samostatne, alebo použite aplikáciu D.Signer.");
      }
      return file;
    });
    var mainIndex = -1;
    for (var i = 0; i < files.length; i++) {
      if (files[i].payloadMimeType === PDF_MIME) { mainIndex = i; break; }
    }
    if (mainIndex === -1) {
      throw new Error("Viac dokumentov naraz Chevron7 podpisuje, len keď je medzi nimi PDF. "
        + "Podpíšte dokumenty jednotlivo, alebo použite aplikáciu D.Signer.");
    }
    var main = files[mainIndex];
    return {
      requestID: newRequestID(),
      filename: main.filename,
      content: main.content,
      payloadMimeType: main.payloadMimeType,
      signatureLevel: options.level || "XAdES_BASELINE_B",
      container: "ASiC_E",
      attachments: files.filter(function (file, index) { return index !== mainIndex; })
    };
  }

  function buildSingleRequest(object, options) {
    var level = options.level || "XAdES_BASELINE_B";
    var file = fileObject(object);

    if (file && file.payloadMimeType === PDF_MIME) {
      // getSignatureWithASiCEnvelopeBase64 expects XAdES in an ASiC-E container
      // around the PDF, exactly as upstream autogram-extension sends it. Without
      // the container the phone relay rejects the request and a card signature
      // comes back as a PAdES PDF the portal cannot use.
      var pdfRequest = {
        requestID: newRequestID(),
        filename: file.filename,
        content: file.content,
        payloadMimeType: file.payloadMimeType,
        signatureLevel: options.level || "PAdES_BASELINE_B"
      };
      if (options.container) {
        pdfRequest.container = options.container;
      }
      return pdfRequest;
    }

    if (object.type === "XadesBp2Xml") {
      // Upstream sends the portal's schema and transformation with the
      // container and embedUsedSchemas = !includeRefs, which addXmlObject2
      // never passes; the engine validates the container against them.
      return {
        requestID: newRequestID(),
        filename: file.filename,
        content: file.content,
        payloadMimeType: file.payloadMimeType,
        signatureLevel: level,
        container: options.container || "ASiC_E",
        eform: {
          containerXmlns: XDC_XMLNS,
          schema: emptyToNull(object.xdcUsedXSD == null ? null : fromBase64(object.xdcUsedXSD)),
          transformation: emptyToNull(object.xdcUsedXSLT == null ? null : fromBase64(object.xdcUsedXSLT)),
          identifier: emptyToNull(object.objectFormatIdentifier),
          schemaIdentifier: null,
          transformationIdentifier: null,
          transformationLanguage: null,
          transformationMediaDestinationTypeDescription: null,
          transformationTargetEnvironment: null,
          embedUsedSchemas: true,
          autoLoadEform: false,
          fsFormID: null,
          packaging: "ENVELOPING"
        }
      };
    }

    if (file) {
      return {
        requestID: newRequestID(),
        filename: file.filename,
        content: file.content,
        payloadMimeType: file.payloadMimeType,
        signatureLevel: level,
        container: options.container || "ASiC_E"
      };
    }

    var isXdc = object.type === "XadesBpXml" || object.type === "XadesXml"
      || object.type === "Xades2Xml";
    if (!isXdc) {
      throw new Error("Typ objektu " + object.type + " zatiaľ nie je podporovaný.");
    }

    var xml, schema, transformation, identifier;
    if (object.type === "XadesBpXml") {
      xml = object.xdcXMLData;
      schema = fromBase64(object.xdcUsedXSD);
      transformation = fromBase64(object.xdcUsedXSLT);
      identifier = formIdentifierWithVersion(object.xdcIdentifier, object.xdcVersion);
    } else {
      xml = object.sourceXml;
      schema = object.sourceXsd;
      transformation = object.sourceXsl;
      identifier = object.namespaceUri;
    }

    return {
      requestID: newRequestID(),
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
      reset();
      if (callback && callback.onError) callback.onError(generalError(error.message));
      return;
    }

    // A failed or cancelled signature drops the document, so the portal's next
    // attempt starts clean instead of being refused as a second document.
    function fail(message, code) {
      reset();
      if (callback && callback.onError) {
        callback.onError(createDitecError(code || ERROR_GENERAL, message));
      }
    }

    function failWithReply(reply) {
      if (reply.cancelled === true) {
        fail(reply.error || "Podpisovanie ste zrušili.", ERROR_CANCELLED);
      } else {
        fail(reply.error || "Podpisovanie zlyhalo.");
      }
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
            failWithReply(reply);
            return;
          }
          setTimeout(function () { poll(jobID); }, POLL_INTERVAL_MS);
          return;
        }
        if (reply.ok !== true) {
          failWithReply(reply);
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
          failWithReply(reply);
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
      reset();
      call("status", null).then(function (reply) {
        if (reply && reply.ok) {
          if (callback && callback.onSuccess) callback.onSuccess();
        } else if (callback && callback.onError) {
          callback.onError(generalError((reply && reply.error) || "Chevron7 nie je dostupný."));
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
      if (callback && callback.onSuccess) callback.onSuccess(DSIGNER_VERSION_JSON);
    },
    getSignerIdentification: function (callback) {
      if (callback && callback.onSuccess) callback.onSuccess(signerIdentification());
    },
    detectSupportedPlatforms: function (platforms, callback) {
      if (callback && callback.onSuccess) callback.onSuccess(["java"]);
    },
    deploy: function (options, callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    deployCancel: function (callback) {
      if (callback && callback.onSuccess) callback.onSuccess();
    },
    loadConfiguration: function (configsZipBase64, callback) {
      unsupported("loadConfiguration", callback);
    },
    getSignatureTimeStampTokenBase64: function (callback) {
      unsupported("getSignatureTimeStampTokenBase64", callback);
    },
    getSignatureTimeStampCert: function (callback) {
      unsupported("getSignatureTimeStampCert", callback);
    },
    getSignatureTimeStampTime: function (callback) {
      unsupported("getSignatureTimeStampTime", callback);
    },
    getTSAIdentification: function (callback) {
      unsupported("getTSAIdentification", callback);
    },
    getSignatureTimeStampRequestBase64: function (reqPolicy, digestAlgUri, callback) {
      unsupported("getSignatureTimeStampRequestBase64", callback);
    },
    getSignatureTimeStampRequest2Base64: function (reqPolicy, digestAlgUri, nonce, certReq, extensions, callback) {
      unsupported("getSignatureTimeStampRequest2Base64", callback);
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

  function signerIdentification() {
    var signedBy = session.signed && session.signed.signedBy;
    if (!signedBy) return SIGNER_PLACEHOLDER;
    return signedBy.indexOf("CN=") === -1 ? "CN=" + signedBy : signedBy;
  }

  /**
   * Collects the documents of one signature. schranka.slovensko.sk chains an
   * add*Object call per document and then signs them together; the getter
   * decides whether they can be (buildMultiRequest). A finished signature
   * starts the next document afresh, and so does initialize, which every
   * portal calls before it adds the first document, so a flow the portal
   * abandoned is never signed together with the next one.
   */
  function storeObject(object, callback) {
    if (session.signed) reset();
    session.objects.push(object);
    if (callback && callback.onSuccess) callback.onSuccess();
  }

  function DSigXadesBpAdapter() {}
  DSigXadesBpAdapter.prototype = Object.create(DSigAdapter.prototype);

  // Constants of the live dSigXadesBp.min.js the portals pass back as
  // addXmlObject arguments; without them schranka sends `undefined`.
  DSigXadesBpAdapter.prototype.XML_MEDIA_DESTINATION_TYPE_DESC_TXT = "TXT";
  DSigXadesBpAdapter.prototype.XML_MEDIA_DESTINATION_TYPE_DESC_HTML = "HTML";
  DSigXadesBpAdapter.prototype.XML_MEDIA_DESTINATION_TYPE_DESC_XHTML = "XHTML";
  DSigXadesBpAdapter.prototype.XML_XDC_NAMESPACE_URI_V1_0 = "http://data.gov.sk/def/container/xmldatacontainer+xml/1.0";
  DSigXadesBpAdapter.prototype.XML_XDC_NAMESPACE_URI_V1_1 = XDC_XMLNS;

  // Revocation checking and mobile signing are the app's own concern: the
  // portal's configuration is acknowledged and the flow continues.
  DSigXadesBpAdapter.prototype.setRevocationChecking = function (ocspCheck, crlCheck, hashAlgorithm, callback) {
    if (callback && callback.onSuccess) callback.onSuccess();
  };
  DSigXadesBpAdapter.prototype.disableMobileSigning = function (callback) {
    if (callback && callback.onSuccess) callback.onSuccess();
  };
  DSigXadesBpAdapter.prototype.getSignatureAndTimeStampWithASiCEnvelopeBase64 = function (callback) {
    unsupported("getSignatureAndTimeStampWithASiCEnvelopeBase64", callback);
  };
  DSigXadesBpAdapter.prototype.createXAdESZepBpT = function (tsResponseB64, tsCertB64, callback) {
    unsupported("createXAdESZepBpT", callback);
  };

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

  /**
   * schranka and nove call this with a ready-made XML Data Container in base64
   * (third argument the form identifier, fourth the container, as upstream
   * autogram-extension reads the real dSigXadesBpJs signature). It is signed as
   * it is, never wrapped into a second container.
   */
  DSigXadesBpAdapter.prototype.addXmlObject2 = function (
    objectId, objectDescription, objectFormatIdentifier, xdcXDCB64, xdcUsedXSD, xdcUsedXSLT, callback
  ) {
    storeObject({
      type: "XadesBp2Xml",
      objectId: objectId,
      objectDescription: objectDescription,
      objectFormatIdentifier: objectFormatIdentifier,
      xdcXDCB64: xdcXDCB64,
      xdcUsedXSD: xdcUsedXSD,
      xdcUsedXSLT: xdcUsedXSLT
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
    var object = session.objects[session.objects.length - 1];
    var original = object && (object.sourcePdfBase64 || object.sourcePngBase64
      || object.xdcXMLData || object.xdcXDCB64 || object.sourceXml || object.sourceTxt);
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

  // XAdES_ZEP 1.1 and 2.0 data envelopes are not signed by Chevron7. They fail
  // the portal's flow visibly: reporting success let it go on to a getter that
  // would sign a different artifact than the one the portal asked for.
  DSigXadesAdapter.prototype.sign11 = function (
    signatureId, digestAlgUri, signaturePolicyIdentifier, dataEnvelopeId,
    dataEnvelopeURI, dataEnvelopeDescr, callback
  ) {
    reset();
    unsupported("sign11", callback);
  };

  DSigXadesAdapter.prototype.sign20 = function (
    signatureId, digestAlgUri, signaturePolicyIdentifier, dataEnvelopeId,
    dataEnvelopeURI, dataEnvelopeDescr, callback
  ) {
    reset();
    unsupported("sign20", callback);
  };

  DSigXadesAdapter.prototype.addPdfObject = DSigXadesBpAdapter.prototype.addPdfObject;
  DSigXadesAdapter.prototype.getConvertedPDFA = DSigXadesBpAdapter.prototype.getConvertedPDFA;

  DSigXadesAdapter.prototype.getSignedXmlWithEnvelope = function (callback) {
    performSignature({ level: "XAdES_BASELINE_B" }, callback);
  };

  // schranka and nove sign every XAdES request through this getter. Like
  // upstream autogram-extension it returns the ASiC-E container, the same
  // artifact as getSignedXmlWithEnvelope.
  DSigXadesAdapter.prototype.getSignedXmlWithEnvelopeBase64 = function (callback) {
    performSignature({ level: "XAdES_BASELINE_B" }, callback);
  };

  DSigXadesAdapter.prototype.getSignedXmlWithEnvelopeAndTimeStamp = function (callback) {
    performSignature({ level: "XAdES_BASELINE_T" }, callback);
  };

  DSigXadesAdapter.prototype.getSignedXmlWithEnvelopeGZipBase64 = function (callback) {
    unsupported("getSignedXmlWithEnvelopeGZipBase64", callback);
  };
  DSigXadesAdapter.prototype.getSignedXmlWithEnvelopeAndTimeStampBase64 = function (callback) {
    unsupported("getSignedXmlWithEnvelopeAndTimeStampBase64", callback);
  };
  DSigXadesAdapter.prototype.getSignedXmlWithEnvelopeAndTimeStampGZipBase64 = function (callback) {
    unsupported("getSignedXmlWithEnvelopeAndTimeStampGZipBase64", callback);
  };
  DSigXadesAdapter.prototype.createXAdESZepT = function (tsResponseB64, tsCertB64, callback) {
    unsupported("createXAdESZepT", callback);
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
    config: { downloadPage: { url: "", title: "" } },
    versions: {}
  };

  // The D.Bridge libraries start with `var ditec = ditec || {}` in strict mode,
  // so their writes into window.ditec throw and they never load. A non-strict
  // build would replace the adapters, so these properties are read-only; only
  // `config` and `versions` stay writable for the portal's config.js.
  function lock(name, value) {
    Object.defineProperty(ditec, name, { value: value, writable: false, enumerable: true, configurable: false });
  }

  lock("isAutogram", true);
  lock("isChevron7", true);
  lock("utils", Object.freeze({
    ERROR_CANCELLED: ERROR_CANCELLED,
    ERROR_GENERAL: ERROR_GENERAL,
    ERROR_NOT_INSTALLED: -201,
    ERROR_LAUNCH_FAILED: -202,
    ERROR_LAUNCH_FORBIDDEN: -203,
    isDitecError: function (error) { return error != null && error.name === "DitecError"; },
    createDitecError: createDitecError,
    extendClass: function () {}
  }));
  lock("dSigXadesJs", new DSigXadesAdapter());
  lock("dSigXadesBpJs", new DSigXadesBpAdapter());

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
