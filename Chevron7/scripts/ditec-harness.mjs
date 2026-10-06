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
function newPage(finalReply) {
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
                        ? (finalReply || { done: true, ok: true, response: JSON.stringify({ content: 'c2lnbmVk', signedBy: 'Test User', issuedBy: 'Test CA' }) })
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
            onError: (e) => resolve({ status: 'error', value: String(e && e.message ? e.message : e), error: e }),
        },
    };
}

async function scenario(name, drive, finalReply) {
    const page = newPage(finalReply);
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

await scenario('Bp2Xml request', async (ditec, page) => {
    const added = cbPair();
    ditec.dSigXadesBpJs.addXmlObject2('form2', 'desc', NS, XML, XSD, XSLT, added.callback);
    check('Bp2Xml addXmlObject2 ok', (await added.promise).status === 'success');
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-5', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    check('Bp2Xml signs', (await signed.promise).status === 'success');
    const req = page.requests[0] || {};
    check('Bp2Xml identifier', req.eform && req.eform.identifier === NS, req.eform && req.eform.identifier);
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

// --- errors reach the page as DitecError objects ---

async function signPdfExpectingError(ditec) {
    const added = cbPair();
    ditec.dSigXadesBpJs.addPdfObject('doc.pdf', 'desc', b64('%PDF-1.4 fake'), '', 'fmt', 0, false, added.callback);
    await added.promise;
    const signed = cbPair();
    ditec.dSigXadesBpJs.sign('sig-c', ditec.dSigXadesBpJs.SHA256, null, { onSuccess: () => {} });
    ditec.dSigXadesBpJs.getSignatureWithASiCEnvelopeBase64(signed.callback);
    return signed.promise;
}

await scenario('cancel is ERROR_CANCELLED', async (ditec) => {
    // schranka.slovensko.sk: `if (e.name === 'DitecError') ... else throw e`, code 1 silenced.
    const out = await signPdfExpectingError(ditec);
    const e = out.error;
    check('cancel reaches onError', out.status === 'error', out.status);
    check('cancel is an Error', e instanceof Error || (e && typeof e.stack === 'string'), typeof e);
    check('cancel name DitecError', e && e.name === 'DitecError', e && e.name);
    check('cancel code', e && e.code === ditec.utils.ERROR_CANCELLED, e && e.code);
    check('cancel message', out.value === 'Podpisovanie ste zrušili.', out.value);
    check('cancel isDitecError', ditec.utils.isDitecError(e) === true);
    check('cancel toString', String(e) === 'DitecError(1) Podpisovanie ste zrušili.', String(e));
}, { done: true, ok: false, cancelled: true, error: 'Podpisovanie ste zrušili.' });

await scenario('failure is ERROR_GENERAL', async (ditec) => {
    const out = await signPdfExpectingError(ditec);
    const e = out.error;
    check('failure name DitecError', e && e.name === 'DitecError', e && e.name);
    check('failure code', e && e.code === ditec.utils.ERROR_GENERAL, e && e.code);
    check('failure message', out.value === 'Certifikáty z karty sa nepodarilo načítať.', out.value);
}, { done: true, ok: false, cancelled: false, error: 'Certifikáty z karty sa nepodarilo načítať.' });

await scenario('isDitecError rejects other values', async (ditec) => {
    check('isDitecError string', ditec.utils.isDitecError('boom') === false);
    check('isDitecError plain Error', ditec.utils.isDitecError(new Error('x')) === false);
});

if (failures > 0) {
    console.log(`\n${failures} check(s) failed`);
    process.exit(1);
}
console.log('\nditec harness: all green');
