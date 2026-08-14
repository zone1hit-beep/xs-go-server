import {createProductionAppleService} from './apple_service.js';
import {loadConfig} from './config.js';
import {startHttpServer} from './http_server.js';

async function main() {
  const config = loadConfig(process.env);
  const service = await createProductionAppleService(config);
  const server = await startHttpServer({
    service,
    token: config.token,
    host: '127.0.0.1',
    port: 9000,
    logger: (message) => process.stderr.write(`${message}\n`),
  });
  const address = server.address();
  process.stdout.write(`Apple verifier ready on ${address.address}:${address.port}\n`);
}

main().catch((error) => {
  process.stderr.write(`Apple verifier failed to start: ${error?.name ?? 'Error'}\n`);
  process.exitCode = 78;
});
