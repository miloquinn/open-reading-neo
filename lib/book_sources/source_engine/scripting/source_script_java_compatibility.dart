// Lexically embedded in the invocation bootstrap; shares its host and collection adapters.
const sourceScriptJavaCompatibility = r'''
  const __NativeString = globalThis.String;
  const __importedGlobals = new Map();
  const __importGlobal = (name, type) => {
    if (!__importedGlobals.has(name)) __importedGlobals.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    globalThis[name] = type;
  };
  const __symmetricCrypto = (transformation, keyValue, ivValue) => ({
    decrypt: (data) => Array.from(__host('symmetricCrypto', [
      'decryptBytes', transformation, keyValue, ivValue, data
    ]) || []),
    decryptStr: (data) => __host('symmetricCrypto', [
      'decryptString', transformation, keyValue, ivValue, data
    ]),
    encrypt: (data) => Array.from(__host('symmetricCrypto', [
      'encryptBytes', transformation, keyValue, ivValue, data
    ]) || []),
    encryptBase64: (data) => __host('symmetricCrypto', [
      'encryptBase64', transformation, keyValue, ivValue, data
    ]),
    encryptHex: (data) => __host('symmetricCrypto', [
      'encryptHex', transformation, keyValue, ivValue, data
    ])
  });
  if (!String.prototype.getBytes) {
    Object.defineProperty(String.prototype, 'getBytes', {
      value: function(charset) { return Array.from(__host('strToBytes', [String(this), charset || 'UTF-8']) || []); },
      enumerable: false
    });
  }
  const __Base64 = {
    NO_WRAP: 2, DEFAULT: 0, NO_PADDING: 1, CRLF: 4, URL_SAFE: 8,
    decode: (value, flags) => Array.from(__host('base64DecodeBytes', [String(value), flags]) || []),
    encodeToString: (value, flags) => __host('base64EncodeBytes', [value, flags === undefined ? 0 : flags]),
    getDecoder: () => ({
      decode: (value) => Array.from(__host('base64DecodeBytes', [String(value)]) || [])
    }),
    getEncoder: () => ({
      encodeToString: (value) => __host('base64EncodeBytes', [value])
    })
  };
  const __SecretKeySpec = function(bytes, algorithm) {
    return { bytes: Array.from(bytes || []), algorithm: String(algorithm || '') };
  };
  const __IvParameterSpec = function(bytes) {
    return { bytes: Array.from(bytes || []) };
  };
  const __Cipher = {
    ENCRYPT_MODE: 1,
    DECRYPT_MODE: 2,
    getInstance: (transformation) => {
      let mode = 2;
      let keySpec = { bytes: [] };
      let ivSpec = { bytes: [] };
      return {
        init: (nextMode, nextKey, nextIv) => {
          mode = Number(nextMode);
          keySpec = nextKey || keySpec;
          ivSpec = nextIv || ivSpec;
        },
        doFinal: (data) => {
          const operation = mode === 1 ? 'encryptBytes' : 'decryptBytes';
          return Array.from(__host('symmetricCrypto', [
            operation,
            String(transformation),
            keySpec.bytes || keySpec,
            ivSpec.bytes || ivSpec,
            data
          ]) || []);
        }
      };
    }
  };
  const __Mac = {
    getInstance: (algorithm) => {
      let keySpec = { bytes: [] };
      return {
        init: (nextKey) => { keySpec = nextKey || keySpec; },
        doFinal: (data) => Array.from(__host('hmacBytes', [
          data, String(algorithm), keySpec.bytes || keySpec
        ]) || [])
      };
    }
  };
  const __MessageDigest = {
    getInstance: (algorithm) => {
      let pending = [];
      return {
        update: (data, offset, length) => {
          const bytes = Array.isArray(data) || ArrayBuffer.isView(data) ? Array.from(data) : [data];
          const start = offset === undefined ? 0 : Number(offset);
          pending.push(bytes.slice(start, length === undefined ? undefined : start + Number(length)));
        },
        reset: () => { pending = []; },
        digest: (data) => {
          if (data !== undefined) pending.push(Array.from(data));
          const bytes = pending.flat();
          pending = [];
          return Array.from(__host('digestBytes', [bytes, String(algorithm)]) || []);
        }
      };
    }
  };
  function __JavaString(value, charsetOrOffset, length, charset) {
    let decoded;
    if (Array.isArray(value) || ArrayBuffer.isView(value)) {
      let bytes = Array.from(value);
      let encoding = charsetOrOffset;
      if (typeof charsetOrOffset === 'number') {
        bytes = bytes.slice(charsetOrOffset, charsetOrOffset + Number(length));
        encoding = charset;
      }
      decoded = __host('bytesToStr', [bytes, encoding || 'UTF-8']);
    } else {
      decoded = value == null ? '' : __NativeString(value);
    }
    return new __NativeString(decoded);
  }
  const __urlEncoder = { encode: (value, charset) => __host('formEncode', [String(value), charset || 'UTF-8']) };
  const __urlDecoder = { decode: (value, charset) => __host('formDecode', [String(value), charset || 'UTF-8']) };
  const __javaBase64Encode = (value, flags) => __host('base64EncodeBytes', [value, flags]).replace(/\r?\n$/, '');
  const __base64Encoder = (flags) => ({
    encodeToString: (value) => __javaBase64Encode(value, flags),
    encode: (value) => __host('strToBytes', [__javaBase64Encode(value, flags), 'ASCII']),
    withoutPadding: () => __base64Encoder(flags | 1)
  });
  const __base64Decoder = () => ({
    decode: (value) => __host('base64DecodeBytes', [Array.isArray(value) ? __host('bytesToStr', [value, 'ASCII']) : String(value)])
  });
  const __JavaBase64 = {
    getEncoder: () => __base64Encoder(2),
    getUrlEncoder: () => __base64Encoder(10),
    getMimeEncoder: () => __base64Encoder(4),
    getDecoder: __base64Decoder,
    getUrlDecoder: __base64Decoder,
    getMimeDecoder: __base64Decoder
  };
  function __ArrayList(values) {
    const list = Array.from(typeof values === 'number' ? [] : values || []);
    Object.defineProperties(list, {
      size: { value: () => list.length },
      get: { value: (index) => list[Number(index)] },
      isEmpty: { value: () => list.length === 0 },
      toArray: { value: () => Array.from(list) },
      remove: { value: (value) => {
        if (typeof value === 'number') {
          if (!Number.isInteger(value) || value < 0 || value >= list.length) throw new RangeError('ArrayList index out of bounds');
          return list.splice(value, 1)[0];
        }
        const index = list.indexOf(value);
        if (index < 0) return false;
        list.splice(index, 1);
        return true;
      } },
      add: { value: function(index, value) {
        if (arguments.length === 1) list.push(index);
        else list.splice(Number(index), 0, value);
        return true;
      } },
      addAll: { value: (items) => { list.push(...Array.from(items)); return true; } },
      set: { value: (index, value) => { const old = list[index]; list[index] = value; return old; } },
      clear: { value: () => { list.length = 0; } },
      contains: { value: (value) => list.includes(value) }
    });
    return list;
  }
  function __HashMap(value) { return __javaMap(typeof value === 'number' ? {} : value); }
  const __javaImports = {
    String: __JavaString, Base64: __Base64,
    SecretKeySpec: __SecretKeySpec, IvParameterSpec: __IvParameterSpec,
    Cipher: __Cipher, Mac: __Mac, MessageDigest: __MessageDigest,
    URLEncoder: __urlEncoder, URLDecoder: __urlDecoder,
    ArrayList: __ArrayList, HashMap: __HashMap
  };
  const __javaClasses = {
    'java.lang.String': __JavaString,
    'java.util.Base64': __JavaBase64,
    'android.util.Base64': __Base64,
    'java.net.URLEncoder': __urlEncoder,
    'java.net.URLDecoder': __urlDecoder,
    'java.util.ArrayList': __ArrayList,
    'java.util.HashMap': __HashMap,
    'java.util.LinkedHashMap': __HashMap,
    'java.security.MessageDigest': __MessageDigest,
    'javax.crypto.Cipher': __Cipher,
    'javax.crypto.Mac': __Mac,
    'javax.crypto.spec.SecretKeySpec': __SecretKeySpec,
    'javax.crypto.spec.IvParameterSpec': __IvParameterSpec
  };
  function __package(path) {
    return new Proxy(function() {
      throw new Error('Unsupported source Java class or method: ' + path);
    }, {
      get: (_, name) => {
        if (name === Symbol.toPrimitive || name === 'toString') return () => path;
        if (typeof name === 'symbol' || name === 'then') return undefined;
        const key = path ? path + '.' + name : String(name);
        return __javaClasses[key] || __package(key);
      }
    });
  }
  globalThis.Packages = __package('');
  const __packageEntries = (pkg) => {
    const type = Object.entries(__javaClasses).find((entry) => entry[1] === pkg);
    if (type) return [type];
    const prefix = String(pkg) + '.';
    return Object.entries(__javaClasses).filter(([name]) => name.startsWith(prefix) && !name.substring(prefix.length).includes('.'));
  };
  globalThis.JavaImporter = function(...packages) {
    const imports = packages.length ? {} : Object.assign({}, __javaImports);
    imports.importPackage = (...values) => {
      for (const pkg of values) {
        for (const [name, type] of __packageEntries(pkg)) imports[name.split('.').pop()] = type;
      }
    };
    imports.importPackage(...packages);
    return imports;
  };
  globalThis.importClass = (type) => {
    const entry = Object.entries(__javaClasses).find((entry) => entry[1] === type);
    if (!entry) throw new Error('Unsupported source Java import: ' + String(type));
    __importGlobal(entry[0].split('.').pop(), type);
  };
  globalThis.importPackage = (...packages) => {
    for (const pkg of packages) {
      for (const [name, type] of __packageEntries(pkg)) __importGlobal(name.split('.').pop(), type);
    }
  };
  if (!Array.prototype.toArray) {
    Object.defineProperty(Array.prototype, 'toArray', {
      value: function() { return Array.from(this); }, enumerable: false
    });
  }
''';
