const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { app, config, client } = require('../server');

test('app configuration has valid defaults', () => {
  assert.equal(config.port, 3000);
  assert.equal(config.databaseName, 'user-account');
  assert.ok(config.mongoUrl.length > 0);
});

test('Firestore errors return a generic response and do not expose details', async (t) => {
  const originalDb = client.db;
  const originalConsoleError = console.error;
  client.db = () => ({
    collection: () => ({
      findOne: async () => { throw new Error('private database detail'); },
    }),
  });
  console.error = () => {};
  const server = app.listen(0);
  await once(server, 'listening');
  t.after(async () => {
    client.db = originalDb;
    console.error = originalConsoleError;
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  });

  const address = server.address();
  const response = await fetch(`http://127.0.0.1:${address.port}/get-profile`);
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: 'database error' });
});

test('health endpoints respond without connecting to Firestore', async (t) => {
  const server = app.listen(0);
  await once(server, 'listening');
  t.after(() => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));

  const address = server.address();
  for (const path of ['/health', '/healthz']) {
    const response = await fetch(`http://127.0.0.1:${address.port}${path}`);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'ok');
  }
});
