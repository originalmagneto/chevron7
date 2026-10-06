// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-FileCopyrightText: Slovensko.Digital and contributors to autogram-extension
// SPDX-License-Identifier: EUPL-1.2
//
// Portal contract scenarios: replays the real signer drivers of
// schranka.slovensko.sk and the nove.slovensko.sk message composer
// (DSignerMulti.js) against the shipped ditec.js. The portal script runs
// verbatim, so argument order, callback chaining, the getVersion plugin gate
// and error branching are the portal's own; only the page shell (eDesk,
// MessageBox, jQuery's $.grep) and the Chevron7 app behind the extension
// channel are test doubles. The PFS scenario is a distillation of the
// financnasprava.sk bundle, which cannot be loaded on its own.
//
// Scenarios, document shapes and the PFS distillation are ported from the
// portal contract tests of slovensko-digital/autogram-extension (EUPL-1.2), v4.0.1.
//
// Usage (repo root, no dependencies):
//   Chevron7/scripts/fetch-portal-fixtures.sh
//   node Chevron7/scripts/portal-contract.mjs
// A missing fixture skips its portal visibly; exit 1 on any failed check.

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
const ditecSource = fs.readFileSync(path.join(root, 'Chevron7', 'WebExtension', 'dist', 'ditec.js'), 'utf8');
const fixtureDir = path.join(root, 'Chevron7', '.build', 'portal-fixtures');
const FIXTURES = {
    schranka: path.join(fixtureDir, 'DSignerMulti-schranka.js'),
    nove: path.join(fixtureDir, 'DSignerMulti-nove.js'),
};

const XDC_MIME = 'application/vnd.gov.sk.xmldatacontainer+xml';
const SIGNED = 'c2lnbmVkLWNvbnRhaW5lcg==';

let failures = 0;
function check(name, cond, extra) {
    if (cond) {
        console.log(`ok: ${name}`);
    } else {
        failures += 1;
        console.log(`FAIL: ${name}${extra !== undefined ? ` (${extra})` : ''}`);
    }
}

// Errors the portal throws from inside a callback (nove's default onError does
// `throw e.code`) surface as uncaught; they are recorded per page, not fatal.
let currentPage = null;
process.on('uncaughtException', (error) => {
    if (currentPage) currentPage.thrown.push(error);
    else throw error;
});
process.on('unhandledRejection', (error) => {
    if (currentPage) currentPage.thrown.push(error);
    else throw error;
});

/**
 * One page: ditec.js plus a fake Chevron7 behind the extension channel.
 * `app.outcome` decides how the next signature ends: 'signed', 'cancelled'
 * (the person closed the panel) or an error message.
 */
function newPage(portalFile) {
    const requests = [];
    const app = { outcome: 'signed' };
    const shell = { errors: [], alerts: [], modals: [] };
    const page = { requests, app, shell, thrown: [] };
    const listeners = new Map();
    const realSetTimeout = setTimeout;
    const realSetImmediate = setImmediate;
    const jobs = new Map();

    const window = {
        addEventListener(type, fn) {
            if (!listeners.has(type)) listeners.set(type, []);
            listeners.get(type).push(fn);
        },
        dispatchEvent(event) {
            if (event.type !== 'chevron7-request') {
                for (const fn of listeners.get(event.type) || []) fn(event);
                return true;
            }
            const { id, kind, request } = event.detail || {};
            const reply = (value) => realSetImmediate(() => {
                for (const fn of listeners.get('chevron7-response') || []) fn({ detail: { id, reply: value } });
            });
            if (kind === 'status') {
                reply({ ok: true });
            } else if (kind === 'sign-begin') {
                requests.push(JSON.parse(request));
                const jobID = `job-${requests.length}`;
                jobs.set(jobID, app.outcome);
                reply({ ok: true, jobID });
            } else if (kind === 'sign-result') {
                const outcome = jobs.get(request);
                if (outcome === 'signed') {
                    reply({ ok: true, done: true, response: JSON.stringify({ content: SIGNED, signedBy: 'Ing. Ján Testovací', issuedBy: 'Test CA' }) });
                } else if (outcome === 'cancelled') {
                    reply({ ok: false, done: true, cancelled: true, error: 'Podpisovanie ste zrušili.' });
                } else {
                    reply({ ok: false, done: true, error: String(outcome) });
                }
            } else {
                reply({ ok: false, error: `unknown kind ${kind}` });
            }
            return true;
        },
    };
    class CustomEvent {
        constructor(type, opts) {
            this.type = type;
            this.detail = (opts || {}).detail;
        }
    }
    const sandbox = {
        window,
        CustomEvent,
        console,
        JSON,
        btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
        atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
        setTimeout: (fn, ms, ...args) => realSetTimeout(fn, Math.min(ms || 0, 10), ...args),
        clearTimeout: (...args) => clearTimeout(...args),
    };
    sandbox.globalThis = sandbox;
    vm.createContext(sandbox);
    vm.runInContext(ditecSource, sandbox, { filename: 'ditec.js' });
    page.ditec = sandbox.window.ditec;

    if (portalFile) {
        const code = fs.readFileSync(portalFile, 'utf8').replace(/^﻿/, '');
        const eDesk = {
            core: {
                modalShow: (id) => shell.modals.push(`show:${id}`),
                modalClose: (id) => shell.modals.push(`close:${id}`),
                compareVersions,
            },
        };
        const MessageBox = { displayError: (message) => shell.errors.push(String(message)) };
        const $ = { grep: (array, fn) => array.filter((item, index) => fn(item, index)) };
        const alert = (message) => shell.alerts.push(String(message));
        const factory = vm.runInContext(
            `(function (ditec, eDesk, MessageBox, $, alert) {\n${code}\n;return { DSigner: DSigner, Callback: Callback };\n})`,
            sandbox,
            { filename: path.basename(portalFile) },
        );
        page.portal = factory(page.ditec, eDesk, MessageBox, $, alert);
    }
    currentPage = page;
    return page;
}

function compareVersions(a, b) {
    const as = String(a).split('.').map(Number);
    const bs = String(b).split('.').map(Number);
    for (let i = 0; i < Math.max(as.length, bs.length); i++) {
        const diff = (as[i] ?? 0) - (bs[i] ?? 0);
        if (diff !== 0) return diff < 0 ? -1 : 1;
    }
    return 0;
}

const settle = (ms = 80) => new Promise((resolve) => setTimeout(resolve, ms));
const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');

function sign(page, request) {
    const out = { result: 'not-called' };
    const signer = new page.portal.DSigner();
    signer.sign(request, (result) => { out.result = result; });
    return out;
}

/** eDesk XDC document as the schranka and nove backends build it. */
function xdcDocument(objectId = 'form-object') {
    return {
        IsXml: true,
        XmlFormId: XDC_MIME,
        ObjectId: objectId,
        Description: 'Všeobecná agenda',
        Uri: 'http://data.gov.sk/doc/eform/App.GeneralAgenda/1.9',
        Data: b64('<XMLDataContainer><XMLData/></XMLDataContainer>'),
        Xsd: '<xs:schema/>',
        Xslt: '<xsl:stylesheet/>',
    };
}

/** eDesk PDF attachment, already PDF/A, so the portal skips the conversion. */
function pdfDocument(objectId = 'priloha.pdf') {
    return {
        IsXml: false,
        IsContainerContent: true,
        ObjectId: objectId,
        Description: 'PDF',
        Uri: 'http://data.gov.sk/def/document/pdf',
        Data: b64('%PDF-1.7 priloha'),
        PdfReqLevel: 0,
    };
}

/** eDesk plain XML form, signed through the 15-argument addXmlObject. */
function plainXmlDocument(objectId = 'plain-xml-object') {
    return {
        IsXml: true,
        XmlFormId: 'http://schemas.gov.sk/form/App.GeneralAgenda/1.9',
        XmlFormVersion: '1.9',
        ObjectId: objectId,
        Description: 'Všeobecná agenda',
        Uri: 'http://data.gov.sk/doc/eform/App.GeneralAgenda/1.9',
        Data: '<GeneralAgenda/>',
        Xsd: '<xs:schema/>',
        XsdUri: 'http://schemas.gov.sk/form/App.GeneralAgenda/1.9/form.xsd',
        Xslt: '<xsl:stylesheet/>',
        XsltUri: 'http://schemas.gov.sk/form/App.GeneralAgenda/1.9/form.xslt',
        XsltIsHtml: false,
        Language: 'sk',
        TargetEnvironment: '',
        EmbedSchemaAndTransformation: false,
    };
}

const asicRequest = (documents) => ({ SignatureType: 'ASiC', SignatureId: 'Signature-1', Documents: documents });
const xadesRequest = (version, documents) => ({
    SignatureType: 'XAdES',
    SignatureId: 'Signature-1',
    XadesZepSignatureVersion: version,
    Documents: documents.map((d) => ({ ...d, XadesZepXMLVerificationDataVersion: '1.0' })),
});

// The portal shows OLD_DSIGNER ("Nainštalujte si najnovší ...") when getVersion
// is not the plugin JSON it parses.
const oldSignerShown = (page) => page.shell.errors.some((e) => e.includes('najnovší'))
    || page.thrown.some((e) => e instanceof SyntaxError);

async function portalScenarios(name, file) {
    if (!fs.existsSync(file)) {
        console.log(`SKIP: ${name} fixture missing, run Chevron7/scripts/fetch-portal-fixtures.sh`);
        return;
    }
    // nove's default onError throws the bare code instead of opening a dialog.
    const showsDialog = name === 'schranka';
    const failedVisibly = (page, text) => showsDialog
        ? page.shell.errors.some((e) => e.includes(text))
        : page.thrown.some((e) => e === -200);

    {
        const page = newPage(file);
        const out = sign(page, asicRequest([xdcDocument()]));
        await settle();
        check(`${name}: XDC form passes the getVersion plugin gate`, !oldSignerShown(page), JSON.stringify(page.shell.errors) + page.thrown.map(String));
        const req = page.requests[0] || {};
        const eform = req.eform || {};
        check(`${name}: XDC form signs`, out.result === SIGNED && page.requests.length === 1,
            JSON.stringify({ result: out.result, errors: page.shell.errors, thrown: page.thrown.map(String) }));
        check(`${name}: XDC form is sent as it is`, req.content === xdcDocument().Data
            && req.payloadMimeType === `${XDC_MIME};base64` && req.filename === 'form-object.xdcf',
            JSON.stringify({ filename: req.filename, mime: req.payloadMimeType }));
        check(`${name}: XDC form identifier is the portal's Uri`, eform.identifier === xdcDocument().Uri, eform.identifier);
        check(`${name}: XDC form carries the portal's schema and transformation`, eform.schema === '<xs:schema/>'
            && eform.transformation === '<xsl:stylesheet/>', JSON.stringify(eform));
    }

    {
        const page = newPage(file);
        const out = sign(page, asicRequest([xdcDocument(), pdfDocument()]));
        await settle();
        const req = page.requests[0] || {};
        const attachments = req.attachments || [];
        check(`${name}: an XDC form with a PDF signs as one container`, out.result === SIGNED && page.requests.length === 1,
            JSON.stringify({ result: out.result, errors: page.shell.errors, thrown: page.thrown.map(String) }));
        check(`${name}: the PDF carries the request, the form follows`, req.filename === 'priloha.pdf' && req.container === 'ASiC_E'
            && attachments.length === 1 && attachments[0].filename === 'form-object.xdcf'
            && attachments[0].payloadMimeType === `${XDC_MIME};base64`,
            JSON.stringify({ filename: req.filename, attachments: attachments.map((a) => a.filename) }));
    }

    {
        const page = newPage(file);
        const out = sign(page, asicRequest([plainXmlDocument()]));
        await settle();
        const req = page.requests[0] || {};
        const eform = req.eform || {};
        check(`${name}: plain XML form signs`, out.result === SIGNED, JSON.stringify({ result: out.result, errors: page.shell.errors, thrown: page.thrown.map(String) }));
        check(`${name}: plain XML mime`, req.payloadMimeType === 'application/xml;base64', req.payloadMimeType);
        check(`${name}: plain XML identifier keeps its version`, eform.identifier === 'http://schemas.gov.sk/form/App.GeneralAgenda/1.9', eform.identifier);
        check(`${name}: plain XML schema and transformation references`, eform.schemaIdentifier === 'http://schemas.gov.sk/form/App.GeneralAgenda/1.9/form.xsd'
            && eform.transformationIdentifier === 'http://schemas.gov.sk/form/App.GeneralAgenda/1.9/form.xslt', JSON.stringify(eform));
        check(`${name}: plain XML media destination constant`, eform.transformationMediaDestinationTypeDescription === 'TXT', eform.transformationMediaDestinationTypeDescription);
        check(`${name}: plain XML schemas referenced, not embedded`, eform.embedUsedSchemas === false, String(eform.embedUsedSchemas));
    }

    {
        const page = newPage(file);
        page.app.outcome = 'cancelled';
        const out = sign(page, asicRequest([plainXmlDocument()]));
        await settle();
        check(`${name}: cancellation stays silent`, out.result === 'not-called' && page.shell.errors.length === 0
            && page.shell.alerts.length === 0 && page.thrown.length === 0, JSON.stringify({ errors: page.shell.errors, thrown: page.thrown.map(String) }));
    }

    {
        const page = newPage(file);
        page.app.outcome = 'podpisovanie zlyhalo';
        const out = sign(page, asicRequest([plainXmlDocument()]));
        await settle();
        check(`${name}: a failed signature reaches the portal`, out.result === 'not-called' && failedVisibly(page, 'podpisovanie zlyhalo'),
            JSON.stringify({ errors: page.shell.errors, thrown: page.thrown.map(String) }));
    }

    {
        const page = newPage(file);
        const out = sign(page, asicRequest([plainXmlDocument('doc-1'), plainXmlDocument('doc-2')]));
        await settle();
        check(`${name}: several plain XML forms are refused, none is signed`, out.result === 'not-called' && page.requests.length === 0
            && failedVisibly(page, 'formulár'), JSON.stringify({ requests: page.requests.length, errors: page.shell.errors, thrown: page.thrown.map(String) }));
        const retry = sign(page, asicRequest([plainXmlDocument('doc-1')]));
        await settle();
        check(`${name}: one document signs after the refusal`, retry.result === SIGNED && page.requests.length === 1, String(retry.result));
    }

    for (const [first, label] of [['podpisovanie zlyhalo', 'a failed'], ['cancelled', 'a cancelled']]) {
        const page = newPage(file);
        page.app.outcome = first;
        sign(page, asicRequest([plainXmlDocument()]));
        await settle();
        const errors = page.shell.errors.length;
        const thrown = page.thrown.length;
        page.app.outcome = 'signed';
        const retry = sign(page, asicRequest([plainXmlDocument()]));
        await settle();
        check(`${name}: a retry after ${label} signature signs`, retry.result === SIGNED
            && page.shell.errors.length === errors && page.thrown.length === thrown,
            JSON.stringify({ result: retry.result, errors: page.shell.errors, thrown: page.thrown.map(String) }));
    }

    {
        const page = newPage(file);
        const out = sign(page, xadesRequest('1.0', [plainXmlDocument()]));
        await settle();
        check(`${name}: XAdES envelope 1.0 signs`, out.result === SIGNED && page.shell.errors.length === 0 && page.thrown.length === 0,
            JSON.stringify({ result: out.result, errors: page.shell.errors, thrown: page.thrown.map(String) }));
    }

    for (const [version, method] of [['1.1', 'sign11'], ['2.0', 'sign20']]) {
        const page = newPage(file);
        const out = sign(page, xadesRequest(version, [plainXmlDocument()]));
        await settle();
        check(`${name}: XAdES envelope ${version} fails visibly through ${method}`, out.result === 'not-called' && page.requests.length === 0
            && failedVisibly(page, method), JSON.stringify({ errors: page.shell.errors, thrown: page.thrown.map(String) }));
    }
}

// --- financnasprava.sk (PFS EKR2, ASiC) ---

/** Verbatim from the PFS bundle (fallback branch: no X509SubjectName tag). */
function getUserNameFromSignature(signature) {
    let userStart = signature.indexOf('X509SubjectName>');
    if (userStart == -1) {
        userStart = signature.indexOf('CN=');
        let userEnd = signature.indexOf(',', userStart + 1);
        if (userEnd == -1) {
            userEnd = signature.indexOf('<', userStart + 1);
            if (userEnd == -1) return signature.substring(userStart + 3);
        }
        return signature.substring(userStart + 3, userEnd);
    }
    const user = signature.substring(userStart, signature.indexOf('X509SubjectName>', userStart + 1));
    userStart = user.indexOf('CN=');
    let userEnd = user.indexOf(',', userStart + 1);
    if (userEnd == -1) userEnd = user.indexOf('<', userStart + 1);
    return user.substring(userStart + 3, userEnd);
}

/** The EKR2 signing sequence as the PFS bundle performs it (Podanie.prototype.Sign). */
function pfsSignFlow(ditec, form) {
    return new Promise((resolve, reject) => {
        const callback = (onSuccess) => ({ onSuccess, onError: reject });
        if (!ditec.dSigXadesBpJs._ready) {
            reject(new Error('PFS would run detectSupportedPlatforms + deploy'));
            return;
        }
        let objectFormatIdentifier = form.xdcNamespaceUri;
        const values = form.xdcNamespaceUri.split('/');
        if (values.length > 1 && form.xdcVersion !== values[values.length - 1]) {
            objectFormatIdentifier = form.xdcNamespaceUri + '/' + form.xdcVersion;
        }
        ditec.dSigXadesBpJs.initialize(callback(() => {
            ditec.dSigXadesBpJs.addXmlObject('Object' + form.objectId, form.objectDescription, objectFormatIdentifier,
                form.contentXml, form.xdcNamespaceUri, form.xdcVersion, form.contentXsd, form.xsdReference,
                form.contentXslt, form.xslReference, 'TXT', '', '', true,
                'http://data.gov.sk/def/container/xmldatacontainer+xml/1.1',
                callback(() => {
                    ditec.dSigXadesBpJs.sign('SignatureId20260710120000', ditec.dSigXadesBpJs.SHA256, '', callback(() => {
                        ditec.dSigXadesBpJs.getSignerIdentification(callback((name) => {
                            const username = getUserNameFromSignature(String(name));
                            ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(callback((signature) => {
                                resolve({ username, signature: String(signature) });
                            }));
                        }));
                    }));
                }));
        }));
    });
}

async function pfsScenario() {
    const page = newPage(null);
    try {
        const { username, signature } = await pfsSignFlow(page.ditec, {
            objectId: '123',
            objectDescription: 'Daňové priznanie k DPH',
            xdcNamespaceUri: 'http://ekrform.financnasprava.sk/Formulare/dphv17',
            xdcVersion: '1.5',
            contentXml: '<dokument/>',
            contentXsd: '<xs:schema/>',
            xsdReference: 'http://ekrform.financnasprava.sk/Formulare/dphv17/form.xsd',
            contentXslt: '<xsl:stylesheet/>',
            xslReference: 'http://ekrform.financnasprava.sk/Formulare/dphv17/form.xsl',
        });
        const req = page.requests[0] || {};
        check('pfs: signs', signature === SIGNED, signature);
        check('pfs: identifier gets the version appended', req.eform && req.eform.identifier === 'http://ekrform.financnasprava.sk/Formulare/dphv17/1.5',
            req.eform && req.eform.identifier);
        check('pfs: signer name before signing parses to a usable name', username.length > 0 && !username.includes('=') && username === username.trim(),
            JSON.stringify(username));
    } catch (error) {
        check('pfs: flow completes', false, String(error && error.message ? error.message : error));
    }
}

// --- ditec.js surface the portals rely on ---

async function surfaceScenarios() {
    const page = newPage(null);
    const ditec = page.ditec;
    check('surface: BP media destination constants', ditec.dSigXadesBpJs.XML_MEDIA_DESTINATION_TYPE_DESC_TXT === 'TXT'
        && ditec.dSigXadesBpJs.XML_MEDIA_DESTINATION_TYPE_DESC_HTML === 'HTML'
        && ditec.dSigXadesBpJs.XML_MEDIA_DESTINATION_TYPE_DESC_XHTML === 'XHTML');
    check('surface: BP XDC namespace constants', ditec.dSigXadesBpJs.XML_XDC_NAMESPACE_URI_V1_1 === 'http://data.gov.sk/def/container/xmldatacontainer+xml/1.1');

    const original = ditec.dSigXadesBpJs;
    try { ditec.dSigXadesBpJs = {}; } catch (error) { /* strict mode in a portal script */ }
    try { ditec.dSigXadesJs = {}; } catch (error) { /* same */ }
    check('surface: a portal script cannot replace the adapters', ditec.dSigXadesBpJs === original && typeof ditec.dSigXadesJs.sign === 'function');
    ditec.config.downloadPage = { url: 'https://example.invalid', title: 'D.Signer' };
    check('surface: config.js may still write its settings', ditec.config.downloadPage.url === 'https://example.invalid');

    for (const [adapter, method, args] of [
        ['dSigXadesBpJs', 'setRevocationChecking', [true, false, 'SHA256']],
        ['dSigXadesBpJs', 'disableMobileSigning', []],
        ['dSigXadesBpJs', 'deployCancel', []],
        ['dSigXadesJs', 'deployCancel', []],
    ]) {
        const result = await new Promise((resolve) => {
            const fn = ditec[adapter][method];
            if (typeof fn !== 'function') return resolve('missing');
            fn.apply(ditec[adapter], [...args, { onSuccess: () => resolve('success'), onError: () => resolve('error') }]);
            setTimeout(() => resolve('no callback'), 200);
        });
        check(`surface: ${adapter}.${method} completes`, result === 'success', result);
    }

    for (const [adapter, method] of [
        ['dSigXadesBpJs', 'getSignatureAndTimeStampWithASiCEnvelopeBase64'],
        ['dSigXadesBpJs', 'loadConfiguration'],
        ['dSigXadesJs', 'getSignedXmlWithEnvelopeGZipBase64'],
        ['dSigXadesJs', 'loadConfiguration'],
    ]) {
        const result = await new Promise((resolve) => {
            const fn = ditec[adapter][method];
            if (typeof fn !== 'function') return resolve('missing');
            const callback = { onSuccess: () => resolve('success'), onError: (e) => resolve(e && e.name === 'DitecError' && e.code === -200 ? 'ditec-error' : `plain ${e}`) };
            fn.apply(ditec[adapter], method === 'loadConfiguration' ? ['', callback] : [callback]);
            setTimeout(() => resolve('no callback'), 200);
        });
        check(`surface: unsupported ${adapter}.${method} fails with a DitecError`, result === 'ditec-error', result);
    }
}

await portalScenarios('schranka', FIXTURES.schranka);
await portalScenarios('nove', FIXTURES.nove);
await pfsScenario();
await surfaceScenarios();
currentPage = null;

if (failures > 0) {
    console.log(`\n${failures} check(s) failed`);
    process.exit(1);
}
console.log('\nportal contract: all green');
