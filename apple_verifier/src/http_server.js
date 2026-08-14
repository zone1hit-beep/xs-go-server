import {createHash, timingSafeEqual} from 'node:crypto';
import http from 'node:http';

class BodyTooLargeError extends Error {}

const digest = (text) => createHash('sha256').update(text).digest();

function authorized(request, expectedToken) {
  const header = request.headers.authorization ?? '';
  const actual = header.startsWith('Bearer ') ? header.slice(7) : '';
  return timingSafeEqual(digest(actual), digest(expectedToken));
}

async function readJson(request, maxBodyBytes) {
  const declared = Number(request.headers['content-length'] ?? 0);
  if (Number.isFinite(declared) && declared > maxBodyBytes) {
    throw new BodyTooLargeError();
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBodyBytes) throw new BodyTooLargeError();
    chunks.push(chunk);
  }
  if (size === 0) return {};
  const decoded = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (decoded === null || Array.isArray(decoded) || typeof decoded !== 'object') {
    throw new SyntaxError('JSON body must be an object');
  }
  return decoded;
}

function send(response, statusCode, body) {
  const encoded = JSON.stringify(body);
  response.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(encoded),
    'cache-control': 'no-store',
  });
  response.end(encoded);
}

export async function startHttpServer({
  service,
  token,
  host = '127.0.0.1',
  port = 9000,
  maxBodyBytes = 384 * 1024,
  logger = () => {},
}) {
  if (!token || token.length < 32) throw new Error('invalid verifier token');
  const server = http.createServer(async (request, response) => {
    if (request.method === 'GET' && request.url === '/health') {
      send(response, 200, {ok: true});
      return;
    }
    if (request.method !== 'POST') {
      send(response, 404, {error: 'not_found'});
      return;
    }
    if (!authorized(request, token)) {
      send(response, 401, {error: 'unauthorized'});
      return;
    }
    try {
      const body = await readJson(request, maxBodyBytes);
      let result;
      if (request.url === '/verify/transaction') {
        result = await service.verifyTransaction(body.signedTransaction);
      } else if (request.url === '/verify/notification') {
        result = await service.verifyNotification(body.signedPayload);
      } else if (request.url === '/transaction/info') {
        result = await service.getTransactionInfo(body.transactionId);
      } else {
        send(response, 404, {error: 'not_found'});
        return;
      }
      send(response, 200, result);
    } catch (error) {
      if (error instanceof BodyTooLargeError) {
        send(response, 413, {error: 'body_too_large'});
        return;
      }
      if (error instanceof SyntaxError) {
        send(response, 400, {error: 'invalid_json'});
        return;
      }
      const statusCode = Number.isInteger(error?.statusCode)
        ? error.statusCode
        : 500;
      logger(`apple verifier request failed: ${error?.code ?? 'internal_error'}`);
      send(response, statusCode, {error: error?.code ?? 'internal_error'});
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, resolve);
  });
  return server;
}
