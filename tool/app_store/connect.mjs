#!/usr/bin/env node

import { readFile, realpath, stat } from 'node:fs/promises';
import { createPrivateKey, sign } from 'node:crypto';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const ASC_BASE_URL = 'https://api.appstoreconnect.apple.com/v1';
export const EXPECTED_BUNDLE_ID = 'com.niki.xxread';
export const DEFAULT_VERSION = '2.6.4';
export const EDITABLE_VERSION_STATES = new Set([
  'PREPARE_FOR_SUBMISSION',
  'DEVELOPER_REJECTED',
]);

export const VERSION_LOCALIZATION_FIELDS = [
  'description',
  'keywords',
  'promotionalText',
  'supportUrl',
  'marketingUrl',
  'whatsNew',
];

export const MANUAL_LOCALIZATION_FIELDS = [
  'name',
  'subtitle',
  'privacyPolicyUrl',
];

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
export const REPOSITORY_ROOT = resolve(MODULE_DIR, '../..');

export class AscHttpError extends Error {
  constructor({ status, code, title }) {
    super([status, code, title].filter(Boolean).join(' '));
    this.name = 'AscHttpError';
    this.status = status;
    this.code = code;
    this.title = title;
  }

  toJSON() {
    return { status: this.status, code: this.code, title: this.title };
  }
}

export function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

export function createAscJwt({ keyId, issuerId, privateKey, now = Date.now() }) {
  if (!keyId || !issuerId || !privateKey) {
    throw new Error('ASC_KEY_ID, ASC_ISSUER_ID, and private key are required');
  }

  const issuedAt = Math.floor(now / 1000);
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
  const payload = base64url(JSON.stringify({
    iss: issuerId,
    iat: issuedAt,
    exp: issuedAt + (19 * 60),
    aud: 'appstoreconnect-v1',
  }));
  const signingInput = `${header}.${payload}`;
  const signature = sign('sha256', Buffer.from(signingInput), {
    key: createPrivateKey(privateKey),
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${base64url(signature)}`;
}

export function isPathInside(parent, child) {
  const pathFromParent = relative(resolve(parent), resolve(child));
  const isOutside = pathFromParent === '..'
    || pathFromParent.startsWith(`..${sep}`)
    || isAbsolute(pathFromParent);
  return pathFromParent !== '' && !isOutside;
}

export async function loadCredentials(env = process.env, { repositoryRoot = REPOSITORY_ROOT } = {}) {
  const keyId = env.ASC_KEY_ID;
  const issuerId = env.ASC_ISSUER_ID;
  const keyPath = env.ASC_KEY_PATH;
  if (!keyId || !issuerId || !keyPath) {
    throw new Error('ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH are required');
  }
  if (!isAbsolute(keyPath)) {
    throw new Error('ASC_KEY_PATH must be absolute');
  }
  let canonicalKeyPath;
  let canonicalRepositoryRoot;
  let keyStat;
  try {
    [canonicalKeyPath, canonicalRepositoryRoot] = await Promise.all([
      realpath(keyPath),
      realpath(repositoryRoot),
    ]);
    keyStat = await stat(canonicalKeyPath);
  } catch {
    throw new Error('Unable to load ASC private key; verify the path and permissions');
  }
  if (!keyStat.isFile()) throw new Error('ASC_KEY_PATH must identify a private-key file');
  if (canonicalKeyPath === canonicalRepositoryRoot || isPathInside(canonicalRepositoryRoot, canonicalKeyPath)) {
    throw new Error('ASC_KEY_PATH must be outside the repository');
  }
  if (keyStat.mode & 0o077) {
    throw new Error('ASC private key permissions must exclude group/other access (chmod 600)');
  }
  try {
    return { keyId, issuerId, privateKey: await readFile(canonicalKeyPath, 'utf8') };
  } catch {
    throw new Error('Unable to load ASC private key; verify the path and permissions');
  }
}

export function timeoutError() {
  return new AscHttpError({
    status: 'TIMEOUT',
    code: 'REQUEST_TIMEOUT',
    title: 'App Store Connect request timed out',
  });
}

export async function ascRequest(path, {
  token,
  method = 'GET',
  body,
  fetchImpl = globalThis.fetch,
  timeoutMs = 15_000,
  baseUrl = ASC_BASE_URL,
} = {}) {
  if (!token) throw new Error('App Store Connect token is required');
  if (typeof fetchImpl !== 'function') throw new Error('fetch is unavailable');

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(`${baseUrl}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: controller.signal,
    });
    if (!response.ok) {
      let errorBody;
      try {
        errorBody = await response.json();
      } catch {
        errorBody = undefined;
      }
      const apiError = errorBody?.errors?.[0] ?? {};
      throw new AscHttpError({
        status: String(apiError.status ?? response.status),
        code: String(apiError.code ?? 'HTTP_ERROR'),
        title: String(apiError.title ?? response.statusText ?? 'App Store Connect request failed'),
      });
    }
    if (response.status === 204) return null;
    return await response.json();
  } catch (error) {
    if (error?.name === 'AbortError') throw timeoutError();
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

export function utf8Length(value) {
  return Buffer.byteLength(value, 'utf8');
}

export function requireString(errors, object, field, locale, { optional = false } = {}) {
  const value = object[field];
  if (value === undefined && optional) return;
  if (typeof value !== 'string') errors.push(`${locale}.${field} must be a string`);
}

export function checkUrl(errors, object, field, locale) {
  const value = object[field];
  if (value === undefined || value === '') return;
  try {
    const parsed = new URL(value);
    if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error();
  } catch {
    errors.push(`${locale}.${field} must be an http(s) URL`);
  }
}

export function validateMetadata(metadata, { forApply = false } = {}) {
  const errors = [];
  const pending = [];
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
    return { valid: false, errors: ['metadata must be an object'], pending };
  }
  if (typeof metadata.bundleId !== 'string' || !metadata.bundleId) errors.push('bundleId is required');
  if (typeof metadata.version !== 'string' || !metadata.version) errors.push('version is required');
  if (!metadata.localizations || typeof metadata.localizations !== 'object' || Array.isArray(metadata.localizations)) {
    errors.push('localizations must be an object');
    return { valid: false, errors, pending };
  }

  const entries = Object.entries(metadata.localizations);
  if (entries.length === 0) errors.push('at least one localization is required');
  for (const [locale, localization] of entries) {
    if (!localization || typeof localization !== 'object' || Array.isArray(localization)) {
      errors.push(`${locale} must be an object`);
      continue;
    }
    for (const field of ['name', 'subtitle', 'description', 'keywords', 'promotionalText', 'supportUrl', 'marketingUrl', 'privacyPolicyUrl']) {
      requireString(errors, localization, field, locale);
    }
    requireString(errors, localization, 'whatsNew', locale, { optional: true });

    if (typeof localization.name === 'string' && characterLength(localization.name) > 30) errors.push(`${locale}.name exceeds 30 characters`);
    if (typeof localization.subtitle === 'string' && characterLength(localization.subtitle) > 30) errors.push(`${locale}.subtitle exceeds 30 characters`);
    if (typeof localization.description === 'string' && characterLength(localization.description) > 4000) errors.push(`${locale}.description exceeds 4000 characters`);
    if (typeof localization.promotionalText === 'string' && characterLength(localization.promotionalText) > 170) errors.push(`${locale}.promotionalText exceeds 170 characters`);
    if (typeof localization.keywords === 'string' && utf8Length(localization.keywords) > 100) errors.push(`${locale}.keywords exceeds 100 UTF-8 bytes`);
    for (const field of ['supportUrl', 'marketingUrl', 'privacyPolicyUrl']) checkUrl(errors, localization, field, locale);

    if (localization.supportUrl === '') {
      const message = `${locale}.supportUrl is required before apply`;
      if (forApply) errors.push(message); else pending.push(message);
    }
    for (const field of MANUAL_LOCALIZATION_FIELDS) {
      if (localization[field] === '') pending.push(`${locale}.${field} requires manual App Store Connect review`);
    }
  }
  return { valid: errors.length === 0, errors, pending };
}

export async function readMetadata(file) {
  let parsed;
  try {
    parsed = JSON.parse(await readFile(resolve(file), 'utf8'));
  } catch (error) {
    throw new Error(`Unable to read metadata JSON: ${error.message}`);
  }
  return parsed;
}

export function buildLocalizationAttributes(localization) {
  return Object.fromEntries(
    VERSION_LOCALIZATION_FIELDS
      .filter((field) => localization[field] !== undefined)
      .map((field) => [field, localization[field]]),
  );
}

export function changedLocalizationAttributes(localization, existingAttributes = {}) {
  return Object.fromEntries(
    Object.entries(buildLocalizationAttributes(localization))
      .filter(([field, value]) => existingAttributes[field] !== value),
  );
}

export function metadataPreview(metadata, validation = validateMetadata(metadata)) {
  return {
    mode: 'dry-run',
    bundleId: metadata.bundleId,
    version: metadata.version,
    localizations: Object.fromEntries(Object.entries(metadata.localizations).map(([locale, value]) => [
      locale,
      { sync: buildLocalizationAttributes(value), manualCheck: Object.fromEntries(MANUAL_LOCALIZATION_FIELDS.map((field) => [field, value[field]])) },
    ])),
    pending: validation.pending,
    manualCheckRequired: MANUAL_LOCALIZATION_FIELDS,
  };
}

export function characterLength(value) {
  return [...value].length;
}

export function requireSingleResource(response, description) {
  if (!Array.isArray(response?.data) || response.data.length !== 1) {
    throw new Error(`Expected exactly one ${description}; found ${response?.data?.length ?? 0}`);
  }
  return response.data[0];
}

export async function findApp(request, bundleId) {
  const response = await request(`/apps?filter%5BbundleId%5D=${encodeURIComponent(bundleId)}&limit=2`);
  const app = requireSingleResource(response, `app for bundle ${bundleId}`);
  if (app.attributes?.bundleId !== bundleId) throw new Error('App Store Connect returned a different bundle ID');
  return app;
}

export async function findVersion(request, appId, version) {
  const response = await request(`/apps/${encodeURIComponent(appId)}/appStoreVersions?filter%5Bplatform%5D=IOS&filter%5BversionString%5D=${encodeURIComponent(version)}&limit=2`);
  const appStoreVersion = requireSingleResource(response, `iOS App Store version ${version}`);
  if (appStoreVersion.attributes?.versionString !== version || appStoreVersion.attributes?.platform !== 'IOS') {
    throw new Error('App Store Connect returned a different iOS version');
  }
  return appStoreVersion;
}

export async function statusCommand({ version = DEFAULT_VERSION, env = process.env, fetchImpl = globalThis.fetch } = {}) {
  const credentials = await loadCredentials(env);
  const token = createAscJwt(credentials);
  const request = (path, options = {}) => ascRequest(path, { token, fetchImpl, ...options });
  const app = await findApp(request, EXPECTED_BUNDLE_ID);
  const [versions, builds, purchases] = await Promise.all([
    request(`/apps/${encodeURIComponent(app.id)}/appStoreVersions?filter%5Bplatform%5D=IOS&limit=200`),
    request(`/builds?filter%5Bapp%5D=${encodeURIComponent(app.id)}&limit=200`),
    request(`/apps/${encodeURIComponent(app.id)}/inAppPurchasesV2?limit=200`),
  ]);
  return {
    app: { id: app.id, ...app.attributes },
    requestedVersion: version,
    versions: (versions.data ?? []).map((item) => ({ id: item.id, ...item.attributes })),
    targetVersion: (versions.data ?? [])
      .filter((item) => item.attributes?.versionString === version)
      .map((item) => ({ id: item.id, ...item.attributes })),
    builds: (builds.data ?? []).map((item) => ({ id: item.id, ...item.attributes })),
    inAppPurchaseProductIds: (purchases.data ?? []).map((item) => item.attributes?.productId).filter(Boolean),
    pagination: {
      limitPerRequest: 200,
      limited: Boolean(versions.links?.next || builds.links?.next || purchases.links?.next),
      note: 'This command reads only the first page of each collection.',
    },
  };
}

export async function applyMetadata(metadata, { env = process.env, fetchImpl = globalThis.fetch } = {}) {
  const validation = validateMetadata(metadata, { forApply: true });
  if (!validation.valid) throw new Error(`Metadata validation failed: ${validation.errors.join('; ')}`);
  if (metadata.bundleId !== EXPECTED_BUNDLE_ID) {
    throw new Error(`Refusing bundle ${metadata.bundleId}; expected ${EXPECTED_BUNDLE_ID}`);
  }

  const credentials = await loadCredentials(env);
  const token = createAscJwt(credentials);
  const request = (path, options = {}) => ascRequest(path, { token, fetchImpl, ...options });
  const app = await findApp(request, metadata.bundleId);
  const version = await findVersion(request, app.id, metadata.version);
  if (!EDITABLE_VERSION_STATES.has(version.attributes?.appStoreState)) {
    throw new Error(`Version ${metadata.version} is locked in state ${version.attributes?.appStoreState ?? 'UNKNOWN'}`);
  }

  const existingResponse = await request(`/appStoreVersions/${encodeURIComponent(version.id)}/appStoreVersionLocalizations?limit=200`);
  if (existingResponse.links?.next) {
    throw new Error('Localization list exceeds the 200-item first-page limit; refusing an incomplete apply');
  }
  const existingByLocale = new Map((existingResponse.data ?? []).map((item) => [item.attributes?.locale, item]));
  const changes = [];
  for (const [locale, localization] of Object.entries(metadata.localizations)) {
    const existing = existingByLocale.get(locale);
    if (existing) {
      const attributes = changedLocalizationAttributes(localization, existing.attributes);
      if (Object.keys(attributes).length === 0) {
        changes.push({ locale, action: 'unchanged' });
        continue;
      }
      await request(`/appStoreVersionLocalizations/${encodeURIComponent(existing.id)}`, {
        method: 'PATCH',
        body: { data: { type: 'appStoreVersionLocalizations', id: existing.id, attributes } },
      });
      changes.push({ locale, action: 'updated', fields: Object.keys(attributes) });
    } else {
      const attributes = { locale, ...buildLocalizationAttributes(localization) };
      await request('/appStoreVersionLocalizations', {
        method: 'POST',
        body: {
          data: {
            type: 'appStoreVersionLocalizations',
            attributes,
            relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } },
          },
        },
      });
      changes.push({ locale, action: 'created', fields: Object.keys(attributes).filter((field) => field !== 'locale') });
    }
  }
  return {
    mode: 'applied',
    bundleId: metadata.bundleId,
    version: metadata.version,
    changes,
    manualCheckRequired: MANUAL_LOCALIZATION_FIELDS,
    paginationLimited: false,
  };
}

export function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (!['status', 'metadata'].includes(command)) throw new Error('Usage: connect.mjs status [--version VERSION] | metadata [--file FILE] [--apply]');
  const result = { command, version: DEFAULT_VERSION, file: 'marketing/app-store/metadata.json', apply: false };
  for (let index = 0; index < rest.length; index += 1) {
    const argument = rest[index];
    if (argument === '--apply' && command === 'metadata') result.apply = true;
    else if (argument === '--version' && command === 'status' && rest[index + 1]) result.version = rest[++index];
    else if (argument === '--file' && command === 'metadata' && rest[index + 1]) result.file = rest[++index];
    else throw new Error(`Unknown or incomplete option: ${argument}`);
  }
  return result;
}

export async function main(argv = process.argv.slice(2), dependencies = {}) {
  const options = parseArgs(argv);
  if (options.command === 'status') return statusCommand({ version: options.version, ...dependencies });

  const metadata = await readMetadata(options.file);
  const validation = validateMetadata(metadata, { forApply: options.apply });
  if (!validation.valid) throw new Error(`Metadata validation failed: ${validation.errors.join('; ')}`);
  if (!options.apply) return metadataPreview(metadata, validation);
  return applyMetadata(metadata, dependencies);
}

export function isMain(metaUrl = import.meta.url, argv1 = process.argv[1]) {
  return Boolean(argv1) && pathToFileURL(resolve(argv1)).href === metaUrl;
}

if (isMain()) {
  main().then(
    (result) => console.log(JSON.stringify(result, null, 2)),
    (error) => {
      const safe = error instanceof AscHttpError ? error.toJSON() : { error: error.message };
      console.error(JSON.stringify(safe));
      process.exitCode = 1;
    },
  );
}
