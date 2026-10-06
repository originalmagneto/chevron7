// Checks the real shipped `ditec.js` end to end: addObject -> sign -> getter,
// capturing the emitted sign-begin request and the page callback.
//
// node Chevron7/scripts/ditec-harness.mjs (repo root, no dependencies)
// Exit 0 when every scenario passes, 1 with the first failure.
//
// Covers the paths `webbridge-probe` cannot: it builds WebSignRequest in Swift
// and never executes this file, the adapters or the getters.

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
const ditecPath = path.join(root, 'Chevron7', 'WebExtension', 'dist', 'ditec.js');
const source = fs.readFileSync(ditecPath, 'utf8');

let failures = 0;
function check(name, cond, extra) {
    if (cond) {
        console.log(`ok: ${name}`);
    } else {
        failures += 1;
        console.log(`FAIL: ${name}${extra !== undefined ? ` (${extra})` : ''}`);
    }
}

// One fresh page per scenario: the shim owns window.ditec's transport and
// answers like the extension would, with the result arriving on the 2nd poll.
function newPage() {
    const requests = [];
    let polls = 0;
     const realSetImmediate = setImmediate;
    const realSetTimeout = setTimeout;
    const listeners = new Map();
    const window = {
        addEventListener(type, fn) {
            if (!listeners.has(type)) listeners.set(type, []);
            listeners.get(type).push(fn);
        },
        dispatchEvent(event) {
            const detail = event.detail || {};
            if (event.type === 'chevron7-request') {
                const { id, kind, request } = detail;
                const replyTo = (reply) => {
                    for (const fn of listeners.get('chevron7-response') || []) {
                        fn({ detail: { id, reply } });
                    }
                };
                if (kind === 'status') {
                    realSetImmediate(() => replyTo({ ok: true }));
                } else if (kind === 'sign-begin') {
                    requests.push(JSON.parse(request));
                    realSetImmediate(() => replyTo({ ok: true, jobID: `job-${requests.length}` }));
                } else if (kind === 'sign-result') {
                    polls += 1;
                    const done = polls >= 2;
                    const reply = done
                        ? { done: true, ok: true, response: JSON.stringify({ content: 'c2lnbmVk', signedBy: 'Test User', issuedBy: 'Test CA' }) }
                        : { done: false, ok: true };
                    realSetImmediate(() => replyTo(reply));
                } else {
                    realSetImmediate(() => replyTo({ ok: false, error: `unknown kind ${kind}` }));
                }
                return true;
            }
            for (const fn of listeners.get(event.type) || []) fn(event);
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
        btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
        atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
        // Poll/backoff only; clamp so the suite stays fast.
        setTimeout: (fn, ms, ...args) => realSetTimeout(fn, Math.min(ms || 0, 10), ...args),
        clearTimeout: (...args) => clearTimeout(...args),
    };
    sandbox.globalThis = sandbox;
    vm.createContext(sandbox);
    vm.runInContext(source, sandbox, { filename: 'ditec.js' });
    return { window: sandbox.window, requests };
}

function cbPair() {
    let resolve, reject;
    const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
    const timer = setTimeout(() => reject(new Error('callback timeout')), 10000);
    return {
        promise: promise.finally(() => clearTimeout(timer)),
        callback: {
            onSuccess: (v) => resolve({ status: 'success', value: v }),
            onError: (e) => resolve({ status: 'error', value: String(e && e.message ? e.message : e) }),
        },
    };
}

async function scenario(name, drive) {
    const page = newPage();
    const ditec = page.window.ditec;
    if (!ditec) {
        check(name, false, 'window.ditec missing');
        return null;
    }
    try {
        const out = await drive(ditec, page);
        return out;
    } catch (e) {
        check(name, false, String(e && e.message ? e.message : e));
        return null;
    }
}

const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');
const XML = '<note><to>portal</to></note>';
const XSD = '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"/>';
const XSLT = '<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"/>';
const NS = 'http://schemas.gov.sk/form/12345678.v1/1.0';

// --- existing branches: must stay byte-identical ---

await scenario('ditec object present', async (ditec) => {
    check('ditec object present', ditec.isChevron7 === true && ditec.isAutogram === true);
});

await scenario('BpXml request', async (ditec, page) => {
    const added = cbPair();
    ditec.dSigXadesBpJs.addXmlObject('Vseobecna_agenda.xdcf', 'desc', 'fmt', XML,
        'form-id', '1.0', b64(XSD), 'xsd-ref', b64(XSLT), 'xslt-ref',
        'HTML', 'SK', 'шки', true, 'urn:xdc', added.callback);
    check('BpXml addXmlObject ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-1', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    const r = await signed.promise;
    check('BpXml signs', r.status === 'success', JSON.stringify(r));
    const req = page.requests[0] || {};
    check('BpXml filename strips double xdcf', req.filename === 'Vseobecna_agenda.xml', req.filename);
    check('BpXml mime', req.payloadMimeType === 'application/xml;base64', req.payloadMimeType);
    check('BpXml container', req.container === 'ASiC_E', req.container);
    check('BpXml identifier', req.eform && req.eform.identifier === 'form-id/1.0', req.eform && req.eform.identifier);
    check('BpXml embed (!includeRefs)', req.eform && req.eform.embedUsedSchemas === false, String(req.eform && req.eform.embedUsedSchemas));
    check('BpXml schema decoded', req.eform && req.eform.schema === XSD, req.eform && req.eform.schema);
});

await scenario('XadesXml request', async (ditec, page) => {
    const added = cbPair();
    ditec.dSigXadesJs.addXmlObject('form1', 'desc', XML, XSD, NS, 'xsd-ref', XSLT, 'xslt-ref', added.callback);
    check('XadesXml addXmlObject ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesJs.sign('sig-2', ditec.dSigXadesJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesJs.getSignedXmlWithEnvelope(signed.callback);
    check('XadesXml signs', (await signed.promise).status === 'success');
    const req = page.requests[0] || {};
    check('XadesXml mime', req.payloadMimeType === 'application/xml;base64', req.payloadMimeType);
    check('XadesXml level B', req.signatureLevel === 'XAdES_BASELINE_B', req.signatureLevel);
    check('XadesXml identifier', req.eform && req.eform.identifier === NS, req.eform && req.eform.identifier);
});

await scenario('XadesXml timestamp level', async (ditec, page) => {
    const added = cbPair();
    ditec.dSigXadesJs.addXmlObject('form1', 'desc', XML, XSD, NS, 'xsd-ref', XSLT, 'xslt-ref', added.callback);
    await added.promise;
    const signed = cbPair();
    ditec.dSigXadesJs.sign('sig-3', ditec.dSigXadesJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesJs.getSignedXmlWithEnvelopeAndTimeStamp(signed.callback);
    check('XadesXml+T signs', (await signed.promise).status === 'success');
    check('XadesXml+T level', (page.requests[0] || {}).signatureLevel === 'XAdES_BASELINE_T', (page.requests[0] || {}).signatureLevel);
});

await scenario('BpPdf request', async (ditec, page) => {
    const added = cbPair();
    ditec.dSigXadesBpJs.addPdfObject('doc.pdf', 'desc', b64('%PDF-1.4 fake'), '', 'fmt', 0, false, added.callback);
    check('BpPdf addPdfObject ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-4', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    check('BpPdf signs', (await signed.promise).status === 'success');
    const req = page.requests[0] || {};
    check('BpPdf mime', req.payloadMimeType === 'application/pdf;base64', req.payloadMimeType);
    check('BpPdf no eform', req.eform == null, JSON.stringify(req.eform));
});

// The portals pass a ready-made base64 XML Data Container here (third argument
// the form identifier). It is signed as it is, as upstream autogram-extension
// sends it: never wrapped into a second container.
await scenario('Bp2Xml request', async (ditec, page) => {
    const xdc = b64('<XMLDataContainer/>');
    const added = cbPair();
    ditec.dSigXadesBpJs.addXmlObject2('Vseobecna_agenda.xdcf', 'desc', NS, xdc, XSD, XSLT, added.callback);
    check('Bp2Xml addXmlObject2 ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-5', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    check('Bp2Xml signs', (await signed.promise).status === 'success');
    const req = page.requests[0] || {};
    check('Bp2Xml filename keeps one xdcf', req.filename === 'Vseobecna_agenda.xdcf', req.filename);
    check('Bp2Xml content passthrough', req.content === xdc, req.content);
    check('Bp2Xml mime', req.payloadMimeType === 'application/vnd.gov.sk.xmldatacontainer+xml;base64', req.payloadMimeType);
    check('Bp2Xml container', req.container === 'ASiC_E', req.container);
    check('Bp2Xml no attachments', req.attachments == null, JSON.stringify(req.attachments));
    check('Bp2Xml identifier', req.eform && req.eform.identifier === NS, req.eform && req.eform.identifier);
    check('Bp2Xml schema and transformation raw', req.eform && req.eform.schema === XSD && req.eform.transformation === XSLT,
        JSON.stringify(req.eform));
    check('Bp2Xml embeds (upstream: no includeRefs)', req.eform && req.eform.embedUsedSchemas === true, String(req.eform && req.eform.embedUsedSchemas));
    check('Bp2Xml container namespace', req.eform && req.eform.containerXmlns === 'http://data.gov.sk/def/container/xmldatacontainer+xml/1.1',
        req.eform && req.eform.containerXmlns);
});

await scenario('Bp2Xml base64 schema', async (ditec, page) => {
    const added = cbPair();
    ditec.dSigXadesBpJs.addXmlObject2('form', 'desc', NS, b64('<XMLDataContainer/>'), b64(XSD), b64(XSLT), added.callback);
    await added.promise;
    const signed = cbPair();
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    await signed.promise;
    const req = page.requests[0] || {};
    check('Bp2Xml filename gets xdcf', req.filename === 'form.xdcf', req.filename);
    check('Bp2Xml base64 schema decoded', req.eform && req.eform.schema === XSD && req.eform.transformation === XSLT, JSON.stringify(req.eform));
});

// schranka chains one add*Object per document into one signature: D.Signer
// returns one ASiC-E whose signature covers every data object.
await scenario('Bp several documents', async (ditec, page) => {
    const pdf = b64('%PDF-1.4 fake');
    const xdc = b64('<XMLDataContainer/>');
    for (const add of [
        (cb) => ditec.dSigXadesBpJs.addTxtObject('poznamka', 'desc', 'Hello world', 'fmt', cb),
        (cb) => ditec.dSigXadesBpJs.addPdfObject('priloha.pdf', 'desc', pdf, '', 'fmt', 0, false, cb),
        (cb) => ditec.dSigXadesBpJs.addXmlObject2('form', 'desc', NS, xdc, XSD, XSLT, cb),
    ]) {
        const added = cbPair();
        add(added.callback);
        check('Bp several: each document is accepted', (await added.promise).status === 'success');
    }
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-6', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    check('Bp several: one signature', (await signed.promise).status === 'success' && page.requests.length === 1, String(page.requests.length));
    const req = page.requests[0] || {};
    check('Bp several: the PDF carries the signature', req.filename === 'priloha.pdf' && req.content === pdf
        && req.payloadMimeType === 'application/pdf;base64', req.filename);
    check('Bp several: an ASiC-E XAdES request', req.container === 'ASiC_E' && req.signatureLevel === 'XAdES_BASELINE_B',
        `${req.container} ${req.signatureLevel}`);
    check('Bp several: no eForm on the request', req.eform == null, JSON.stringify(req.eform));
    const attachments = req.attachments || [];
    check('Bp several: the others in portal order', attachments.length === 2
        && attachments[0].filename === 'poznamka.txt' && attachments[0].payloadMimeType === 'text/plain;base64'
        && Buffer.from(attachments[0].content, 'base64').toString('utf8') === 'Hello world'
        && attachments[1].filename === 'form.xdcf' && attachments[1].content === xdc
        && attachments[1].payloadMimeType === 'application/vnd.gov.sk.xmldatacontainer+xml;base64',
        JSON.stringify(attachments.map((a) => [a.filename, a.payloadMimeType])));
});

for (const [label, adds, text] of [
    ['without a PDF', (d, cb1, cb2) => {
        d.dSigXadesBpJs.addTxtObject('a', 'desc', 'A', 'fmt', cb1);
        d.dSigXadesBpJs.addPngObject('b', 'desc', b64('png'), 'fmt', cb2);
    }, 'PDF'],
    ['with a form built from XML', (d, cb1, cb2) => {
        d.dSigXadesBpJs.addPdfObject('a.pdf', 'desc', b64('%PDF-1.4'), '', 'fmt', 0, false, cb1);
        d.dSigXadesBpJs.addXmlObject('form', 'desc', 'fmt', XML, 'form-id', '1.0', b64(XSD), 'xsd', b64(XSLT), 'xsl',
            'TXT', 'sk', '', false, 'http://data.gov.sk/def/container/xmldatacontainer+xml/1.1', cb2);
    }, 'formulár'],
]) {
    await scenario(`Bp several ${label}`, async (ditec, page) => {
        const first = cbPair();
        const second = cbPair();
        adds(ditec, first.callback, second.callback);
        await first.promise;
        await second.promise;
        const signed = cbPair();
        ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
        const r = await signed.promise;
        check(`Bp several ${label}: refused with a reason`, r.status === 'error' && r.value.includes(text), JSON.stringify(r));
        check(`Bp several ${label}: nothing sent`, page.requests.length === 0, String(page.requests.length));
    });
}

// A XAdES envelope with several documents is a different artifact (one XML
// signature over several references), not an ASiC-E: refused, not substituted.
await scenario('Xades several documents', async (ditec, page) => {
    const first = cbPair();
    const second = cbPair();
    ditec.dSigXadesJs.addPdfObject('a.pdf', 'desc', b64('%PDF-1.4'), '', 'fmt', 0, false, first.callback);
    ditec.dSigXadesJs.addPdfObject('b.pdf', 'desc', b64('%PDF-1.4'), '', 'fmt', 0, false, second.callback);
    await first.promise;
    await second.promise;
    const signed = cbPair();
    ditec.dSigXadesJs.getSignedXmlWithEnvelopeBase64(signed.callback);
    const r = await signed.promise;
    check('Xades several: refused', r.status === 'error' && r.value.includes('XAdES'), JSON.stringify(r));
    check('Xades several: nothing sent', page.requests.length === 0, String(page.requests.length));
});

// A portal that added a document and walked away must not have it signed with
// the next one: initialize starts every portal's signing flow afresh.
await scenario('initialize drops an abandoned document', async (ditec, page) => {
    const stale = cbPair();
    ditec.dSigXadesBpJs.addPdfObject('stary.pdf', 'desc', b64('%PDF-1.4 old'), '', 'fmt', 0, false, stale.callback);
    await stale.promise;
    const init = cbPair();
    ditec.dSigXadesBpJs.initialize(init.callback);
    check('initialize succeeds', (await init.promise).status === 'success');
    const added = cbPair();
    ditec.dSigXadesBpJs.addPdfObject('novy.pdf', 'desc', b64('%PDF-1.4 new'), '', 'fmt', 0, false, added.callback);
    await added.promise;
    const signed = cbPair();
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    await signed.promise;
    const req = page.requests[0] || {};
    check('initialize: only the new document is signed', req.filename === 'novy.pdf' && req.attachments == null,
        `${req.filename} ${JSON.stringify(req.attachments)}`);
});

// --- new branches ---

await scenario('legacy stubs', async (ditec) => {
    check('sign11 stubbed', typeof ditec.dSigXadesJs.sign11 === 'function');
    check('sign20 stubbed', typeof ditec.dSigXadesJs.sign20 === 'function');
    check('getConvertedPDFA present', typeof ditec.dSigXadesBpJs.getConvertedPDFA === 'function');
});

await scenario('XadesBpTxt request', async (ditec, page) => {
    if (typeof ditec.dSigXadesBpJs.addTxtObject !== 'function') {
        check('Bp addTxtObject exists', false);
        return;
    }
    const added = cbPair();
    ditec.dSigXadesBpJs.addTxtObject('poznamka', 'desc', 'Hello world', 'fmt', added.callback);
    check('BpTxt addTxtObject ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-6', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    const r = await signed.promise;
    check('BpTxt signs', r.status === 'success', JSON.stringify(r));
    const req = page.requests[0] || {};
    check('BpTxt mime', req.payloadMimeType === 'text/plain;base64', req.payloadMimeType);
    check('BpTxt no eform', req.eform == null, JSON.stringify(req.eform));
    check('BpTxt content', Buffer.from(req.content || '', 'base64').toString('utf8') === 'Hello world', req.content);
});

await scenario('XadesBpPng request', async (ditec, page) => {
    if (typeof ditec.dSigXadesBpJs.addPngObject !== 'function') {
        check('Bp addPngObject exists', false);
        return;
    }
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    const added = cbPair();
    ditec.dSigXadesBpJs.addPngObject('obrazok', 'desc', png, 'fmt', added.callback);
    check('BpPng addPngObject ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-7', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    check('BpPng signs', (await signed.promise).status === 'success');
    const req = page.requests[0] || {};
    check('BpPng mime', req.payloadMimeType === 'image/png;base64', req.payloadMimeType);
    check('BpPng no eform', req.eform == null, JSON.stringify(req.eform));
    check('BpPng content passthrough', req.content === png, (req.content || '').slice(0, 20));
});

await scenario('Xades addXmlObject2', async (ditec, page) => {
    if (typeof ditec.dSigXadesJs.addXmlObject2 !== 'function') {
        check('Xades addXmlObject2 exists', false);
        return;
    }
    const added = cbPair();
    ditec.dSigXadesJs.addXmlObject2('form3', 'desc', XML, XSD, NS, 'xsd-ref', XSLT, 'xslt-ref', 'XDC', added.callback);
    check('Xades2Xml addXmlObject2 ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesJs.sign('sig-8', ditec.dSigXadesJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesJs.getSignedXmlWithEnvelope(signed.callback);
    check('Xades2Xml signs', (await signed.promise).status === 'success');
    const req = page.requests[0] || {};
    check('Xades2Xml identifier', req.eform && req.eform.identifier === NS, req.eform && req.eform.identifier);
});

await scenario('Xades addTxt/addPng', async (ditec) => {
    check('Xades addTxtObject exists', typeof ditec.dSigXadesJs.addTxtObject === 'function');
    check('Xades addPngObject exists', typeof ditec.dSigXadesJs.addPngObject === 'function');
});

if (failures > 0) {
    console.log(`\n${failures} check(s) failed`);
    process.exit(1);
}
console.log('\nditec harness: all green');
