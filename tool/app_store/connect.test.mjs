import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { chmod, mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  AscHttpError,
  applyMetadata,
  ascRequest,
  createAscJwt,
  isPathInside,
  loadCredentials,
  main,
  statusCommand,
  validateMetadata,
} from './connect.mjs';

const BUNDLE_ID = 'com.niki.xxread';

function validLocalization(overrides = {}) {
  return {
    name: '开卷阅读',
    subtitle: '自由阅读',
    description: '阅读工具',
    keywords: '阅读,电子书',
    promotionalText: '开始阅读',
    supportUrl: 'https://example.com/support',
    marketingUrl: 'https://example.com',
    privacyPolicyUrl: 'https://example.com/privacy',
    whatsNew: '首次发布',
    ...overrides,
  };
}

function validMetadata(overrides = {}) {
  return {
    bundleId: BUNDLE_ID,
    version: '2.6.4',
    localizations: { 'zh-Hans': validLocalization() },
    ...overrides,
  };
}

function jsonResponse(data, { status = 200, statusText = 'OK' } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText,
    async json() { return data; },
  };
}

async function keyEnvironment() {
  const directory = await mkdtemp(join(tmpdir(), 'open-reading-asc-'));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const keyPath = join(directory, 'AuthKey_TEST.p8');
  await writeFile(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  return { ASC_KEY_ID: 'TESTKEY123', ASC_ISSUER_ID: 'issuer-test', ASC_KEY_PATH: keyPath };
}

test('JWT uses ES256 claims and a 64-byte P1363 signature without containing the private key', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const jwt = createAscJwt({ keyId: 'KEY', issuerId: 'ISSUER', privateKey: pem, now: 1_700_000_000_000 });
  const [headerPart, payloadPart, signaturePart] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(headerPart, 'base64url')), { alg: 'ES256', kid: 'KEY', typ: 'JWT' });
  assert.deepEqual(JSON.parse(Buffer.from(payloadPart, 'base64url')), {
    iss: 'ISSUER', iat: 1_700_000_000, exp: 1_700_001_140, aud: 'appstoreconnect-v1',
  });
  assert.equal(Buffer.from(signaturePart, 'base64url').length, 64);
  assert.equal(jwt.includes('PRIVATE'), false);
});

test('metadata defaults to local-only dry run and does not need credentials', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'open-reading-metadata-'));
  const file = join(directory, 'metadata.json');
  await writeFile(file, JSON.stringify(validMetadata()));
  let fetchCalls = 0;
  const result = await main(['metadata', '--file', file], {
    env: {},
    fetchImpl: async () => { fetchCalls += 1; throw new Error('unexpected network'); },
  });
  assert.equal(fetchCalls, 0);
  assert.equal(result.mode, 'dry-run');
  assert.deepEqual(result.manualCheckRequired, ['name', 'subtitle', 'privacyPolicyUrl']);
});

test('apply uses global fetch when no fetch dependency is supplied', async () => {
  const env = await keyEnvironment();
  const { calls, fetchImpl } = makeApplyFetch();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    await applyMetadata(validMetadata(), { env });
    assert.ok(calls.length >= 4);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('local validation reports missing support URL as pending but apply rejects it', () => {
  const metadata = validMetadata({ localizations: { 'zh-Hans': validLocalization({ supportUrl: '' }) } });
  const local = validateMetadata(metadata);
  assert.equal(local.valid, true);
  assert.match(local.pending[0], /supportUrl/);
  const apply = validateMetadata(metadata, { forApply: true });
  assert.equal(apply.valid, false);
  assert.match(apply.errors[0], /supportUrl/);
});

test('blank manual-only metadata is pending and does not block apply validation', () => {
  const metadata = validMetadata({ localizations: { 'zh-Hans': validLocalization({ privacyPolicyUrl: '' }) } });
  const result = validateMetadata(metadata, { forApply: true });
  assert.equal(result.valid, true);
  assert.equal(result.pending.some((item) => item.includes('privacyPolicyUrl')), true);
});

test('metadata length limits cover characters and UTF-8 keyword bytes', () => {
  for (const [field, value, expected] of [
    ['name', '名'.repeat(31), /name exceeds 30/],
    ['subtitle', '副'.repeat(31), /subtitle exceeds 30/],
    ['description', '文'.repeat(4001), /description exceeds 4000/],
    ['promotionalText', '推'.repeat(171), /promotionalText exceeds 170/],
    ['keywords', '书'.repeat(34), /keywords exceeds 100 UTF-8 bytes/],
  ]) {
    const metadata = validMetadata({ localizations: { 'zh-Hans': validLocalization({ [field]: value }) } });
    assert.equal(validateMetadata(metadata).errors.some((error) => expected.test(error)), true, field);
  }
});

test('HTTP errors expose only status, code, and title', async () => {
  for (const status of [401, 404]) {
    const fetchImpl = async () => jsonResponse({ errors: [{ status: String(status), code: 'SAFE_CODE', title: 'Safe title', detail: 'private detail' }] }, { status, statusText: 'failure' });
    await assert.rejects(
      ascRequest('/apps', { token: 'secret-token', fetchImpl }),
      (error) => {
        assert.ok(error instanceof AscHttpError);
        assert.deepEqual(error.toJSON(), { status: String(status), code: 'SAFE_CODE', title: 'Safe title' });
        assert.equal(error.message.includes('private detail'), false);
        assert.equal(error.message.includes('secret-token'), false);
        return true;
      },
    );
  }
});

test('request timeout is sanitized', async () => {
  const fetchImpl = async (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted with internal data'), { name: 'AbortError' })));
  });
  await assert.rejects(ascRequest('/apps', { token: 'secret', fetchImpl, timeoutMs: 5 }), (error) => {
    assert.deepEqual(error.toJSON(), { status: 'TIMEOUT', code: 'REQUEST_TIMEOUT', title: 'App Store Connect request timed out' });
    return true;
  });
});

test('request timeout remains active while reading a successful response body', async () => {
  const fetchImpl = async (_url, { signal }) => ({
    ok: true,
    status: 200,
    async json() {
      return new Promise((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(Object.assign(new Error('private body error'), { name: 'AbortError' })));
      });
    },
  });
  await assert.rejects(ascRequest('/apps', { token: 'secret', fetchImpl, timeoutMs: 5 }), (error) => {
    assert.deepEqual(error.toJSON(), { status: 'TIMEOUT', code: 'REQUEST_TIMEOUT', title: 'App Store Connect request timed out' });
    return true;
  });
});

test('path containment accepts sibling names beginning with two dots', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'open-reading-path-'));
  const repository = join(directory, 'repo');
  await mkdir(repository);
  assert.equal(isPathInside(repository, join(repository, '..private.p8')), true);
  assert.equal(isPathInside(repository, join(directory, 'private.p8')), false);
});

test('credentials reject group-readable keys and hide filesystem paths on read errors', async () => {
  const env = await keyEnvironment();
  await chmod(env.ASC_KEY_PATH, 0o644);
  await assert.rejects(loadCredentials(env), /permissions.*chmod 600/);

  const missingPath = join(tmpdir(), 'private-secret-name-that-must-not-leak.p8');
  await assert.rejects(
    loadCredentials({ ...env, ASC_KEY_PATH: missingPath }),
    (error) => {
      assert.equal(error.message.includes(missingPath), false);
      assert.equal(error.message.includes('private-secret-name'), false);
      return true;
    },
  );
});

test('status reads the expected bundle, iOS versions, builds, and IAP product IDs with pagination disclosure', async () => {
  const env = await keyEnvironment();
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    const parsed = new URL(url);
    if (parsed.pathname === '/v1/apps') return jsonResponse({ data: [{ id: 'app-1', attributes: { bundleId: BUNDLE_ID } }] });
    if (parsed.pathname === '/v1/apps/app-1/appStoreVersions') return jsonResponse({ data: [{ id: 'v-1', attributes: { platform: 'IOS', versionString: '2.6.4' } }], links: { next: 'next-page' } });
    if (parsed.pathname === '/v1/builds') return jsonResponse({ data: [{ id: 'b-1', attributes: { version: '42' } }] });
    if (parsed.pathname === '/v1/apps/app-1/inAppPurchasesV2') return jsonResponse({ data: [{ id: 'iap-1', attributes: { productId: 'pro.lifetime' } }] });
    throw new Error(`Unexpected request: ${url}`);
  };
  const result = await statusCommand({ env, fetchImpl });
  assert.equal(result.app.bundleId, BUNDLE_ID);
  assert.equal(result.targetVersion[0].versionString, '2.6.4');
  assert.equal(result.builds[0].version, '42');
  assert.deepEqual(result.inAppPurchaseProductIds, ['pro.lifetime']);
  assert.equal(result.pagination.limited, true);
  assert.equal(calls.some((url) => url.includes('filter%5BbundleId%5D=com.niki.xxread')), true);
});

function makeApplyFetch({ state = 'PREPARE_FOR_SUBMISSION', returnedBundle = BUNDLE_ID, localizationNext = false } = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    const parsed = new URL(url);
    if (parsed.pathname === '/v1/apps') return jsonResponse({ data: [{ type: 'apps', id: 'app-1', attributes: { bundleId: returnedBundle } }] });
    if (parsed.pathname === '/v1/apps/app-1/appStoreVersions') {
      return jsonResponse({ data: [{ type: 'appStoreVersions', id: 'version-1', attributes: { versionString: '2.6.4', platform: 'IOS', appStoreState: state } }] });
    }
    if (parsed.pathname === '/v1/appStoreVersions/version-1/appStoreVersionLocalizations') {
      return jsonResponse({
        data: [{ type: 'appStoreVersionLocalizations', id: 'loc-zh', attributes: { locale: 'zh-Hans', description: '旧描述' } }],
        links: localizationNext ? { next: 'next-page' } : {},
      });
    }
    if (parsed.pathname === '/v1/appStoreVersionLocalizations/loc-zh' && options.method === 'PATCH') return jsonResponse({ data: {} });
    if (parsed.pathname === '/v1/appStoreVersionLocalizations' && options.method === 'POST') return jsonResponse({ data: {} }, { status: 201 });
    throw new Error(`Unexpected request: ${options.method} ${parsed.pathname}`);
  };
  return { calls, fetchImpl };
}

test('apply locks to the configured bundle and rejects a different ASC bundle', async () => {
  const env = await keyEnvironment();
  const { fetchImpl } = makeApplyFetch({ returnedBundle: 'com.example.other' });
  await assert.rejects(applyMetadata(validMetadata(), { env, fetchImpl }), /different bundle ID/);
  await assert.rejects(applyMetadata(validMetadata({ bundleId: 'com.example.other' }), { env, fetchImpl }), /Refusing bundle/);
});

test('apply rejects a non-editable existing version before localization writes', async () => {
  const env = await keyEnvironment();
  const { calls, fetchImpl } = makeApplyFetch({ state: 'READY_FOR_SALE' });
  await assert.rejects(applyMetadata(validMetadata(), { env, fetchImpl }), /locked in state READY_FOR_SALE/);
  assert.equal(calls.some((call) => ['POST', 'PATCH'].includes(call.options.method)), false);
});

test('apply refuses an incomplete localization page before writes', async () => {
  const env = await keyEnvironment();
  const { calls, fetchImpl } = makeApplyFetch({ localizationNext: true });
  await assert.rejects(applyMetadata(validMetadata(), { env, fetchImpl }), /first-page limit/);
  assert.equal(calls.some((call) => ['POST', 'PATCH'].includes(call.options.method)), false);
});

test('apply sends minimal PATCH fields and never writes app-info-only fields', async () => {
  const env = await keyEnvironment();
  const { calls, fetchImpl } = makeApplyFetch();
  await applyMetadata(validMetadata(), { env, fetchImpl });
  const patch = calls.find((call) => call.options.method === 'PATCH');
  const body = JSON.parse(patch.options.body);
  assert.equal(body.data.id, 'loc-zh');
  assert.equal(body.data.type, 'appStoreVersionLocalizations');
  assert.equal('locale' in body.data.attributes, false);
  assert.equal('name' in body.data.attributes, false);
  assert.equal('subtitle' in body.data.attributes, false);
  assert.equal('privacyPolicyUrl' in body.data.attributes, false);
  assert.equal(body.data.attributes.description, '阅读工具');
});

test('apply POST includes only version-localization fields and relationship', async () => {
  const env = await keyEnvironment();
  const { calls, fetchImpl } = makeApplyFetch();
  const metadata = validMetadata({
    localizations: {
      'zh-Hans': validLocalization({ description: '旧描述' }),
      'en-US': validLocalization({ name: 'Open Reading', subtitle: 'Read freely', description: 'Reader' }),
    },
  });
  await applyMetadata(metadata, { env, fetchImpl });
  const post = calls.find((call) => call.options.method === 'POST');
  const data = JSON.parse(post.options.body).data;
  assert.equal(data.attributes.locale, 'en-US');
  assert.equal(data.attributes.description, 'Reader');
  assert.equal('name' in data.attributes, false);
  assert.equal('subtitle' in data.attributes, false);
  assert.equal('privacyPolicyUrl' in data.attributes, false);
  assert.deepEqual(data.relationships.appStoreVersion.data, { type: 'appStoreVersions', id: 'version-1' });
});

test('apply authenticates requests without putting the JWT in URLs or bodies', async () => {
  const env = await keyEnvironment();
  const { calls, fetchImpl } = makeApplyFetch();
  await applyMetadata(validMetadata(), { env, fetchImpl });
  for (const call of calls) {
    assert.match(call.options.headers.Authorization, /^Bearer [^.]+\.[^.]+\.[^.]+$/);
    assert.equal(call.url.includes(call.options.headers.Authorization.slice(7)), false);
    assert.equal((call.options.body ?? '').includes(call.options.headers.Authorization.slice(7)), false);
  }
});
