const express = require('express');
const path = require('path');
const fs = require('fs');
const { MongoClient } = require('mongodb');
const bodyParser = require('body-parser');

const app = express();
app.use(bodyParser.urlencoded({ extended: true }));
app.use(bodyParser.json());

// Connection string comes from the environment.
//  - On GCP: Firestore with MongoDB compatibility, authenticated with the VM's
//    service account (MONGODB-OIDC, ENVIRONMENT:gcp) - no username or password.
//    mongodb://<uid>.<location>.firestore.goog:443/user-account?loadBalanced=true&tls=true
//      &retryWrites=false&authMechanism=MONGODB-OIDC
//      &authMechanismProperties=ENVIRONMENT:gcp,TOKEN_RESOURCE:FIRESTORE
//  - Locally: falls back to the mongo container from docker-compose.yaml.
const config = {
  port: Number(process.env.PORT || 3000),
  mongoUrl: process.env.MONGO_URL || 'mongodb://admin:password@localhost:27017',
  databaseName: process.env.MONGO_DB_NAME || 'user-account',
};
if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) {
  throw new Error('PORT must be an integer between 1 and 65535');
}

// On Firestore the database name must match the Firestore database ID.
const collectionName = 'users';

// One client for the whole process: it keeps a connection pool and caches the
// OIDC token, instead of re-authenticating on every request.
const client = new MongoClient(config.mongoUrl);
const users = () => client.db(config.databaseName).collection(collectionName);
const log = (severity, message, error) => {
  const entry = {
    'logging.googleapis.com/severity': severity,
    message,
    ...(error ? { errorType: error.name } : {}),
  };
  const line = JSON.stringify(entry);
  if (severity === 'ERROR') console.error(line);
  else console.log(line);
  if (process.env.LOG_FILE) fs.appendFileSync(process.env.LOG_FILE, `${line}\n`);
};

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

// health check used by the deploy pipeline (does not touch the database)
const healthCheck = (req, res) => {
  res.status(200).send('ok');
};
app.get('/health', healthCheck);
app.get('/healthz', healthCheck); // compatibility with existing LB and deploy checks

app.get('/profile-picture', (req, res) => {
  const img = fs.readFileSync(path.join(__dirname, 'images/profile-1.jpg'));
  res.writeHead(200, { 'Content-Type': 'image/jpg' });
  res.end(img, 'binary');
});

app.get('/get-profile', async (req, res) => {
  try {
    const result = await users().findOne({ userid: 1 }, { projection: { _id: 0 } });
    res.send(result || {});
  } catch (err) {
    log('ERROR', 'get-profile failed', err);
    res.status(500).send({ error: 'database error' });
  }
});

app.post('/update-profile', async (req, res) => {
  const userObj = { ...req.body, userid: 1 };
  try {
    await users().updateOne({ userid: 1 }, { $set: userObj }, { upsert: true });
    res.send(userObj);
  } catch (err) {
    log('ERROR', 'update-profile failed', err);
    res.status(500).send({ error: 'database error' });
  }
});

if (require.main === module) {
  app.listen(config.port, () => {
    log('INFO', 'app listening');
  });
}

process.on('SIGTERM', async () => {
  await client.close();
  if (require.main === module) process.exit(0);
});

module.exports = { app, config, client };
