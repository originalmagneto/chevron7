// Reference only: the host resolves the installed bundle and supplies its permitted paths.
import { spawn } from 'node:child_process';

export function callChevron7(helper, session, args, { signal } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(helper, ['--session', session, ...args, '--json'], {
      shell: false, stdio: ['ignore', 'pipe', 'pipe'], signal, timeout: 120000,
    });
    let stdout = '';
    let size = 0;
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      size += Buffer.byteLength(chunk, 'utf8');
      if (size > 4 * 1024 * 1024) { child.kill('SIGTERM'); reject(new Error('Chevron7 response exceeds limit; inspect job before retrying.')); return; }
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => { if (stderr.length < 16384) stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code) => {
      try {
        const response = JSON.parse(stdout);
        if (response.apiVersion !== 1 || typeof response.ok !== 'boolean') throw new Error('Incompatible Chevron7 response');
        resolve({ code, response });
      } catch (error) { reject(new Error(`Missing valid Chevron7 result. Outcome may be unknown. ${stderr}`, { cause: error })); }
    });
  });
}

// Persist requestKey before calling. Do not generate a new key to retry an uncertain request.
export async function beginSignature({ helper, session, root, file, output, requestKey }) {
  return callChevron7(helper, session, [
    'sign', file, '--output', output, '--format', 'pades', '--level', 'B',
    '--root', root, '--request-key', requestKey, '--no-wait',
  ]);
}

export async function getSignatureJob({ helper, session, root, jobId }) {
  return callChevron7(helper, session, ['jobs', 'get', jobId, '--root', root]);
}

export async function cancelSignatureJob({ helper, session, root, jobId }) {
  return callChevron7(helper, session, ['jobs', 'cancel', jobId, '--root', root]);
}
