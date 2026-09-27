/// LX Music 音源脚本的运行环境（宿主 shim），以 JS 源码形式注入 QuickJS。
///
/// 契约依据：<https://lxmusic.toside.cn/desktop/custom-source>
/// 参考实现：<https://github.com/lyswhut/lx-music-desktop>（Apache-2.0）
///
/// 这个 shim 只提供脚本**用得上的宿主能力**，不提供任何网络/文件访问：
///   - `globalThis.lx`：version / env / currentScriptInfo / EVENT_NAMES
///   - `lx.on(event, handler)` / `lx.send(event, data)`
///   - `lx.request(url, options, callback)`  → 转成 Dart 侧 HTTP，再由宿主投递回来
///   - `lx.utils`：buffer / str2b64 / b642str / crypto.md5（sha1、sha256 见下）
///
/// 宿主通道（JS → Dart，消息体一律是 JSON 字符串）：
///   - `hoh_inited`   脚本上报初始化结果（inited / updateAlert）
///   - `hoh_request`  脚本发起请求
///   - `hoh_result`   宿主调用处理器后的返回值 / 异常
///   - `hoh_log`      脚本里的 send() 非 inited 事件，当调试日志
///
/// 宿主通道（Dart → JS，统一走 `__hohDeliver(json)`）：
///   - `{kind:'response', id, error, resp, body}`  投递请求结果
///   - `{kind:'invoke',  id, action, source, quality, info}`  调用脚本处理器
///   - `{kind:'ping'}` / `{kind:'utilsTest'}`      自检用
///
/// ⚠️ 注意：`flutter_js` 的 `runtime.sendMessage()`（Dart → JS）在 0.8.7 里
/// 会去调用一个并未定义的 `DART_TO_QUICKJS_CHANNEL_sendMessage`，等于不可用；
/// 所以 Dart → JS 一律用 `evaluate('__hohDeliver(...)')` 这条自有通道。
library;

const String lxShimJs = r'''
(function () {
  if (globalThis.__hoh && globalThis.__hoh.ready) return;

  // ── 一些打包器生成的脚本会先探测全局对象，补上常见的几个名字 ──
  if (typeof globalThis.window === 'undefined') globalThis.window = globalThis;
  if (typeof globalThis.self === 'undefined') globalThis.self = globalThis;
  if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;

  var H = globalThis.__hoh = {
    ready: true,
    handlers: {},          // 脚本注册的事件处理器
    pending: {},           // 请求 id -> 回调
    requestSeq: 0,
    initedPayload: null,
    initedSent: false,
    utilsTest: null
  };

  function post(channel, payload) {
    try {
      sendMessage(channel, JSON.stringify(payload));
    } catch (e) {
      // 通道都不通了就没什么能做的了，别把脚本拖死
    }
  }
  H.post = post;

  function errText(e) {
    if (e === null || e === undefined) return '未知错误';
    if (typeof e === 'string') return e;
    if (e.message) return String(e.message);
    try { return JSON.stringify(e); } catch (_) { return String(e); }
  }
  H.errText = errText;

  // ── Base64（UTF-8 友好）──────────────────────────────────────────
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';

  function toUtf8(s) { return unescape(encodeURIComponent(String(s))); }
  function fromUtf8(s) { return decodeURIComponent(escape(String(s))); }

  function b64encode(str) {
    var input = toUtf8(str), out = '', i = 0, c1, c2, c3;
    while (i < input.length) {
      c1 = input.charCodeAt(i++);
      c2 = input.charCodeAt(i++);
      c3 = input.charCodeAt(i++);
      out += B64.charAt(c1 >> 2);
      out += B64.charAt(((c1 & 3) << 4) | (isNaN(c2) ? 0 : c2 >> 4));
      out += isNaN(c2) ? '=' : B64.charAt(((c2 & 15) << 2) | (isNaN(c3) ? 0 : c3 >> 6));
      out += isNaN(c3) ? '=' : B64.charAt(c3 & 63);
    }
    return out;
  }

  function b64decode(str) {
    var input = String(str).replace(/[^A-Za-z0-9+/=]/g, ''), out = '', i = 0;
    while (i < input.length) {
      var e1 = B64.indexOf(input.charAt(i++));
      var e2 = B64.indexOf(input.charAt(i++));
      var e3 = B64.indexOf(input.charAt(i++));
      var e4 = B64.indexOf(input.charAt(i++));
      if (e1 < 0) break;
      var c1 = (e1 << 2) | (e2 < 0 || e2 === 64 ? 0 : e2 >> 4);
      var c2 = ((e2 < 0 ? 0 : e2 & 15) << 4) | (e3 < 0 || e3 === 64 ? 0 : e3 >> 2);
      var c3 = ((e3 < 0 ? 0 : e3 & 3) << 6) | (e4 < 0 || e4 === 64 ? 0 : e4);
      out += String.fromCharCode(c1);
      if (e3 >= 0 && e3 !== 64) out += String.fromCharCode(c2);
      if (e4 >= 0 && e4 !== 64) out += String.fromCharCode(c3);
    }
    return fromUtf8(out);
  }

  // ── MD5（UTF-8 输入 → 小写 hex）──────────────────────────────────
  function safeAdd(x, y) {
    var lsw = (x & 0xffff) + (y & 0xffff);
    var msw = (x >> 16) + (y >> 16) + (lsw >> 16);
    return (msw << 16) | (lsw & 0xffff);
  }
  function rol(num, cnt) { return (num << cnt) | (num >>> (32 - cnt)); }
  function md5cmn(q, a, b, x, s, t) {
    return safeAdd(rol(safeAdd(safeAdd(a, q), safeAdd(x, t)), s), b);
  }
  function ff(a, b, c, d, x, s, t) { return md5cmn((b & c) | (~b & d), a, b, x, s, t); }
  function gg(a, b, c, d, x, s, t) { return md5cmn((b & d) | (c & ~d), a, b, x, s, t); }
  function hh(a, b, c, d, x, s, t) { return md5cmn(b ^ c ^ d, a, b, x, s, t); }
  function ii(a, b, c, d, x, s, t) { return md5cmn(c ^ (b | ~d), a, b, x, s, t); }

  function md5cycle(x, k) {
    var a = x[0], b = x[1], c = x[2], d = x[3];
    a = ff(a, b, c, d, k[0], 7, -680876936);
    d = ff(d, a, b, c, k[1], 12, -389564586);
    c = ff(c, d, a, b, k[2], 17, 606105819);
    b = ff(b, c, d, a, k[3], 22, -1044525330);
    a = ff(a, b, c, d, k[4], 7, -176418897);
    d = ff(d, a, b, c, k[5], 12, 1200080426);
    c = ff(c, d, a, b, k[6], 17, -1473231341);
    b = ff(b, c, d, a, k[7], 22, -45705983);
    a = ff(a, b, c, d, k[8], 7, 1770035416);
    d = ff(d, a, b, c, k[9], 12, -1958414417);
    c = ff(c, d, a, b, k[10], 17, -42063);
    b = ff(b, c, d, a, k[11], 22, -1990404162);
    a = ff(a, b, c, d, k[12], 7, 1804603682);
    d = ff(d, a, b, c, k[13], 12, -40341101);
    c = ff(c, d, a, b, k[14], 17, -1502002290);
    b = ff(b, c, d, a, k[15], 22, 1236535329);
    a = gg(a, b, c, d, k[1], 5, -165796510);
    d = gg(d, a, b, c, k[6], 9, -1069501632);
    c = gg(c, d, a, b, k[11], 14, 643717713);
    b = gg(b, c, d, a, k[0], 20, -373897302);
    a = gg(a, b, c, d, k[5], 5, -701558691);
    d = gg(d, a, b, c, k[10], 9, 38016083);
    c = gg(c, d, a, b, k[15], 14, -660478335);
    b = gg(b, c, d, a, k[4], 20, -405537848);
    a = gg(a, b, c, d, k[9], 5, 568446438);
    d = gg(d, a, b, c, k[14], 9, -1019803690);
    c = gg(c, d, a, b, k[3], 14, -187363961);
    b = gg(b, c, d, a, k[8], 20, 1163531501);
    a = gg(a, b, c, d, k[13], 5, -1444681467);
    d = gg(d, a, b, c, k[2], 9, -51403784);
    c = gg(c, d, a, b, k[7], 14, 1735328473);
    b = gg(b, c, d, a, k[12], 20, -1926607734);
    a = hh(a, b, c, d, k[5], 4, -378558);
    d = hh(d, a, b, c, k[8], 11, -2022574463);
    c = hh(c, d, a, b, k[11], 16, 1839030562);
    b = hh(b, c, d, a, k[14], 23, -35309556);
    a = hh(a, b, c, d, k[1], 4, -1530992060);
    d = hh(d, a, b, c, k[4], 11, 1272893353);
    c = hh(c, d, a, b, k[7], 16, -155497632);
    b = hh(b, c, d, a, k[10], 23, -1094730640);
    a = hh(a, b, c, d, k[13], 4, 681279174);
    d = hh(d, a, b, c, k[0], 11, -358537222);
    c = hh(c, d, a, b, k[3], 16, -722521979);
    b = hh(b, c, d, a, k[6], 23, 76029189);
    a = hh(a, b, c, d, k[9], 4, -640364487);
    d = hh(d, a, b, c, k[12], 11, -421815835);
    c = hh(c, d, a, b, k[15], 16, 530742520);
    b = hh(b, c, d, a, k[2], 23, -995338651);
    a = ii(a, b, c, d, k[0], 6, -198630844);
    d = ii(d, a, b, c, k[7], 10, 1126891415);
    c = ii(c, d, a, b, k[14], 15, -1416354905);
    b = ii(b, c, d, a, k[5], 21, -57434055);
    a = ii(a, b, c, d, k[12], 6, 1700485571);
    d = ii(d, a, b, c, k[3], 10, -1894986606);
    c = ii(c, d, a, b, k[10], 15, -1051523);
    b = ii(b, c, d, a, k[1], 21, -2054922799);
    a = ii(a, b, c, d, k[8], 6, 1873313359);
    d = ii(d, a, b, c, k[15], 10, -30611744);
    c = ii(c, d, a, b, k[6], 15, -1560198380);
    b = ii(b, c, d, a, k[13], 21, 1309151649);
    a = ii(a, b, c, d, k[4], 6, -145523070);
    d = ii(d, a, b, c, k[11], 10, -1120210379);
    c = ii(c, d, a, b, k[2], 15, 718787259);
    b = ii(b, c, d, a, k[9], 21, -343485551);
    x[0] = safeAdd(a, x[0]);
    x[1] = safeAdd(b, x[1]);
    x[2] = safeAdd(c, x[2]);
    x[3] = safeAdd(d, x[3]);
  }

  function md5(input) {
    var s = toUtf8(input), len = s.length, i;
    var words = [];
    for (i = 0; i < len; i++) {
      words[i >> 2] = (words[i >> 2] || 0) | ((s.charCodeAt(i) & 0xff) << ((i % 4) * 8));
    }
    words[len >> 2] = (words[len >> 2] || 0) | (0x80 << ((len % 4) * 8));
    var total = (((len + 8) >> 6) + 1) * 16;
    for (i = 0; i < total; i++) if (words[i] === undefined) words[i] = 0;
    words[total - 2] = len * 8;
    words[total - 1] = 0;
    var state = [1732584193, -271733879, -1732584194, 271733878];
    for (i = 0; i < total; i += 16) md5cycle(state, words.slice(i, i + 16));
    var hex = '', x, tab = '0123456789abcdef';
    for (i = 0; i < state.length; i++) {
      x = state[i];
      for (var j = 0; j < 4; j++) {
        hex += tab.charAt((x >>> ((j * 8) + 4)) & 0x0f) + tab.charAt((x >>> (j * 8)) & 0x0f);
      }
    }
    return hex;
  }

  // ── buffer 工具（LX 里当 Node Buffer 用，这里用轻量替身）──────────
  function bufFrom(data, encoding) {
    if (data && data.__hohBuf) return data;
    var s = '';
    if (typeof data === 'string') {
      if (encoding === 'base64') s = b64decode(data);
      else if (encoding === 'hex') {
        for (var i = 0; i + 1 < data.length; i += 2) {
          s += String.fromCharCode(parseInt(data.substr(i, 2), 16));
        }
      } else s = data;
    } else if (data instanceof ArrayBuffer) {
      var view = new Uint8Array(data);
      for (var k = 0; k < view.length; k++) s += String.fromCharCode(view[k]);
    } else if (Object.prototype.toString.call(data) === '[object Array]') {
      for (var m = 0; m < data.length; m++) s += String.fromCharCode(data[m] & 0xff);
    } else if (data === undefined || data === null) {
      s = '';
    } else {
      s = String(data);
    }
    return { __hohBuf: true, v: s };
  }

  function bufToString(buf, encoding) {
    var s = (buf && buf.__hohBuf) ? buf.v : (buf === undefined || buf === null ? '' : String(buf));
    if (encoding === 'hex') {
      var h = '';
      for (var i = 0; i < s.length; i++) {
        h += ('0' + s.charCodeAt(i).toString(16)).slice(-2);
      }
      return h;
    }
    if (encoding === 'base64') return b64encode(s);
    return s;
  }

  // ── AES-128（兼容 LX 音源常用的 ECB/CBC）────────────────────────
  // QuickJS 没有 Node crypto；这里使用纯 JS 实现，避免把桌面平台专属
  // 加密库塞进音源协议。输入/输出都保持 LX Buffer 替身格式。
  function aesMul(a, b) {
    var out = 0;
    for (var i = 0; i < 8; i++) {
      if (b & 1) out ^= a;
      var hi = a & 0x80;
      a = (a << 1) & 0xff;
      if (hi) a ^= 0x1b;
      b >>>= 1;
    }
    return out & 0xff;
  }
  function aesPow(a, n) {
    var out = 1;
    while (n > 0) {
      if (n & 1) out = aesMul(out, a);
      a = aesMul(a, a);
      n >>>= 1;
    }
    return out;
  }
  function aesRotl8(x, n) { return ((x << n) | (x >>> (8 - n))) & 0xff; }
  function aesSbox(x) {
    var inv = x === 0 ? 0 : aesPow(x, 254);
    return (inv ^ aesRotl8(inv, 1) ^ aesRotl8(inv, 2) ^
      aesRotl8(inv, 3) ^ aesRotl8(inv, 4) ^ 0x63) & 0xff;
  }
  function aesSubBytes(state) {
    for (var i = 0; i < 16; i++) state[i] = aesSbox(state[i]);
  }
  function aesShiftRows(state) {
    var copy = state.slice(0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 4; col++) {
        state[row + col * 4] = copy[row + ((col + row) % 4) * 4];
      }
    }
  }
  function aesMixColumns(state) {
    for (var col = 0; col < 4; col++) {
      var i = col * 4;
      var a0 = state[i], a1 = state[i + 1], a2 = state[i + 2], a3 = state[i + 3];
      state[i] = aesMul(a0, 2) ^ aesMul(a1, 3) ^ a2 ^ a3;
      state[i + 1] = a0 ^ aesMul(a1, 2) ^ aesMul(a2, 3) ^ a3;
      state[i + 2] = a0 ^ a1 ^ aesMul(a2, 2) ^ aesMul(a3, 3);
      state[i + 3] = aesMul(a0, 3) ^ a1 ^ a2 ^ aesMul(a3, 2);
    }
  }
  function aesKeyExpansion(key) {
    var expanded = key.slice(0, 16);
    while (expanded.length < 16) expanded.push(0);
    var rcon = 1;
    for (var bytes = 16; bytes < 176; bytes += 4) {
      var t = expanded.slice(bytes - 4, bytes);
      if (bytes % 16 === 0) {
        t = [t[1], t[2], t[3], t[0]];
        for (var j = 0; j < 4; j++) t[j] = aesSbox(t[j]);
        t[0] ^= rcon;
        rcon = aesMul(rcon, 2);
      }
      for (var k = 0; k < 4; k++) expanded.push(
        expanded[bytes - 16 + k] ^ t[k]
      );
    }
    return expanded;
  }
  function aesAddRoundKey(state, key, offset) {
    for (var i = 0; i < 16; i++) state[i] ^= key[offset + i];
  }
  function aesEncryptBlock(block, key) {
    var state = block.slice(0);
    aesAddRoundKey(state, key, 0);
    for (var round = 1; round < 10; round++) {
      aesSubBytes(state);
      aesShiftRows(state);
      aesMixColumns(state);
      aesAddRoundKey(state, key, round * 16);
    }
    aesSubBytes(state);
    aesShiftRows(state);
    aesAddRoundKey(state, key, 160);
    return state;
  }
  function aesBytes(value) {
    if (value && value.__hohBuf) {
      var binary = value.v || '', out = [];
      for (var i = 0; i < binary.length; i++) out.push(binary.charCodeAt(i) & 0xff);
      return out;
    }
    var text = String(value === undefined || value === null ? '' : value);
    var utf8 = unescape(encodeURIComponent(text)), result = [];
    for (var j = 0; j < utf8.length; j++) result.push(utf8.charCodeAt(j) & 0xff);
    return result;
  }
  function aesEncrypt(data, key, iv, mode) {
    var input = aesBytes(data), keyBytes = aesBytes(key).slice(0, 16);
    while (keyBytes.length < 16) keyBytes.push(0);
    var expanded = aesKeyExpansion(keyBytes), pad = 16 - (input.length % 16);
    for (var i = 0; i < pad; i++) input.push(pad);
    var cbc = String(mode || '').toLowerCase().indexOf('cbc') >= 0;
    var previous = aesBytes(iv).slice(0, 16);
    while (previous.length < 16) previous.push(0);
    var output = [];
    for (var offset = 0; offset < input.length; offset += 16) {
      var block = input.slice(offset, offset + 16);
      if (cbc) for (var b = 0; b < 16; b++) block[b] ^= previous[b];
      var encrypted = aesEncryptBlock(block, expanded);
      for (var e = 0; e < 16; e++) output.push(encrypted[e]);
      if (cbc) previous = encrypted;
    }
    return bufFrom(output);
  }

  // ── lx 主体 ─────────────────────────────────────────────────────
  var lx = globalThis.lx = {
    version: '2.6.0',
    env: 'desktop',
    EVENT_NAMES: {
      request: 'request',
      inited: 'inited',
      updateAlert: 'updateAlert'
    },
    currentScriptInfo: {
      name: '', description: '', version: '', author: '', homepage: '', rawScript: ''
    },
    on: function (eventName, handler) {
      if (eventName !== lx.EVENT_NAMES.request || typeof handler !== 'function') {
        return Promise.reject(new Error('The event is not supported: ' + eventName));
      }
      H.handlers[eventName] = handler;
      // LX 的官方实现返回 Promise；不少新音源会 await/on(...).then(...)
      return Promise.resolve();
    },
    send: function (eventName, data) {
      if (eventName !== lx.EVENT_NAMES.inited && eventName !== lx.EVENT_NAMES.updateAlert) {
        return Promise.reject(new Error('The event is not supported: ' + eventName));
      }
      if (eventName === 'inited') {
        if (H.initedSent) return Promise.reject(new Error('Script is inited'));
        H.initedSent = true;
        H.initedPayload = data;
        post('hoh_inited', { payload: data === undefined ? null : data });
        return Promise.resolve();
      }
      if (eventName === 'updateAlert') {
        post('hoh_update_alert', { payload: data === undefined ? null : data });
        return Promise.resolve();
      }
    },
    request: function (url, options, callback) {
      options = options || {};
      var id = String(++H.requestSeq);
      if (typeof callback === 'function') H.pending[id] = callback;
      var payload = {
        id: id,
        url: String(url),
        method: options.method || 'GET',
        headers: options.headers || null,
        body: typeof options.body === 'string' ? options.body : null,
        form: options.form || null,
        formData: options.formData || null,
        timeout: options.timeout || 0
      };
      post('hoh_request', payload);
      // LX 返回取消函数，而不是请求 id；保留 id 在闭包里供宿主中止请求。
      return function () { post('hoh_request', { kind: 'cancel', id: id }); };
    },
    utils: {
      buffer: { from: bufFrom, bufToString: bufToString },
      str2b64: function (str) { return b64encode(str); },
      b642str: function (str) { return b64decode(str); },
      crypto: {
        md5: md5,
        randomBytes: function (size) {
          var s = '';
          for (var i = 0; i < (size || 8); i++) s += String.fromCharCode(Math.floor(Math.random() * 256));
          return bufFrom(s);
        },
        sha1: function () { throw new Error('宿主未实现 sha1，请在 HoH music 里反馈该音源'); },
        sha256: function () { throw new Error('宿主未实现 sha256，请在 HoH music 里反馈该音源'); },
        aesEncrypt: function (data, mode, key, iv) {
          return aesEncrypt(data, key, iv, mode);
        },
        rsaEncrypt: function () { throw new Error('宿主未实现 rsaEncrypt'); }
      }
    }
  };

  // ── 宿主 → 脚本 的唯一入口 ───────────────────────────────────────
  globalThis.__hohDeliver = function (json) {
    var msg;
    try { msg = JSON.parse(json); } catch (e) { return 'bad json'; }
    try {
      if (msg.kind === 'response') {
        var cb = H.pending[msg.id];
        delete H.pending[msg.id];
        if (typeof cb === 'function') cb(msg.error || null, msg.resp || null, msg.body);
        return 'ok';
      }
      if (msg.kind === 'invoke') {
        var handler = H.handlers.request;
        if (typeof handler !== 'function') {
          post('hoh_result', { id: msg.id, ok: false, error: '脚本没有注册 request 处理器' });
          return 'ok';
        }
        var arg = { source: msg.source, action: msg.action, info: msg.info };
        if (msg.action === 'musicUrl') arg.quality = msg.quality;
        var out;
        try {
          out = handler(arg);
        } catch (e) {
          post('hoh_result', { id: msg.id, ok: false, error: errText(e) });
          return 'ok';
        }
        if (out && typeof out.then === 'function') {
          out.then(function (data) {
            post('hoh_result', { id: msg.id, ok: true, data: data === undefined ? null : data });
          }, function (e) {
            post('hoh_result', { id: msg.id, ok: false, error: errText(e) });
          });
        } else {
          post('hoh_result', { id: msg.id, ok: true, data: out === undefined ? null : out });
        }
        return 'ok';
      }
      if (msg.kind === 'utilsTest') {
        H.utilsTest = {
          md5_abc: lx.utils.crypto.md5('abc'),
          md5_cn: lx.utils.crypto.md5('晴天'),
          b64_cn: lx.utils.str2b64('晴天'),
          b64_round: lx.utils.b642str(lx.utils.str2b64('晴天-周杰伦')),
          hex_round: lx.utils.buffer.bufToString(lx.utils.buffer.from('HoH', 'utf8'), 'hex')
        };
        post('hoh_utils_test', H.utilsTest);
        return 'ok';
      }
      if (msg.kind === 'ping') { post('hoh_pong', { at: msg.at }); return 'ok'; }
    } catch (e) {
      post('hoh_error', { where: 'deliver', error: errText(e) });
    }
    return 'unknown kind';
  };

  globalThis.__hohIsInited = function () {
    return H.initedPayload ? JSON.stringify(H.initedPayload) : '';
  };
  1;
})();
''';
