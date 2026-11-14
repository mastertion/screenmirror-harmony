/*
 * TLS-PSK 传输模块（libsectls.so）
 *
 * spacedesk 服务器开启 "Password Protection and Encryption" 后，
 * 客户端必须用 TLS-PSK 连接，键盘输入才被服务器接受。
 *
 * ===== 密钥协议（已对官方安卓客户端 spacedesk_81828_kf.apk 字节码逆向确认）=====
 *   包名: ph.spacedesk.beta（APK 自带 BouncyCastle 实现整条 TLS-PSK 栈，无原生库）
 *   PSK identity = "Client_identity"
 *      证据: ph/spacedesk/httpwww/spacedesk/g2.1.smali:29  const-string p1, "Client_identity"
 *   PSK 密钥     = hex_decode(密码字符串 + "1A1A...1A"(共32个hex字符,即16字节0x1A))
 *      证据: ph/spacedesk/httpwww/spacedesk/g2.1.smali:81  const-string v1, "1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A"
 *            该串在 g2.c() 中与密码拼接后交给 BouncyCastle PSK 回调（最终 hex 解码成字节）。
 *   加密模式枚举 b$c（ph/spacedesk/httpwww/spacedesk/b$c.smali）：
 *      X="None"(不加密) / Y="TLS1_2" / Z="TLS1_3"
 *   密码套件（SAPSKTlsClient.H()，m2.1.smali:117）：
 *      TLS1_3 模式(Z) → 0x1303 = TLS_AES_128_GCM_SHA256
 *      TLS1_2 模式(Y) → 0xccac = TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
 *   数据路径上除 TLS 外无额外加/解密层（已确认 spacedesk 包内无 javax.crypto/Cipher/Hmac）。
 *
 *   实现要点：
 *   外部 PSK 统一走 psk_client_callback（OpenSSL 同时用于 TLS1.2 与 TLS1.3），
 *   不注册 psk_use_session_callback（1.3 会话回调在本机实测会导致握手失败）。
 *   TLS1.2 套件同时提供 纯PSK 与 ECDHE-PSK（匹配官方客户端 TLS1_2 模式的 ECDHE-PSK-ChaCha20），
 *   TLS1.3 套件用默认（AES-GCM / CHACHA20，与已验证可用的官方客户端一致）。
 *   TLS 之上跑与明文完全相同的 spacedesk 报文协议。
 */
#include "napi/native_api.h"
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <map>
#include <memory>
#include <vector>
#include <hilog/log.h>

#define LOG_DOMAIN 0x3200
#define LOG_TAG "SdSecure"

static const char* PSK_IDENTITY = "Client_identity";

/** 读线程 → JS 线程的事件 */
struct SdTlsEvent {
  int type;                      // 0=data, 1=eof, 2=error
  std::vector<uint8_t> data;
  std::string message;
};

struct SdTlsConn {
  int id = 0;
  int fd = -1;
  SSL_CTX* ctx = nullptr;
  SSL* ssl = nullptr;
  std::string psk;               // PSK 原始字节
  std::atomic<bool> closed{false};
  std::atomic<bool> tsfReleased{false};
  napi_threadsafe_function tsf = nullptr;
};

static std::mutex g_mutex;
static std::map<int, std::shared_ptr<SdTlsConn>> g_conns;
static int g_nextId = 1;

static std::string SslErrorText() {
  unsigned long e = ERR_get_error();
  if (e == 0) {
    int err = errno;
    if (err != 0) {
      return std::string("TLS syscall error: ") + strerror(err);
    }
    return "TLS error (peer closed / 0-byte)";
  }
  char buf[256] = {0};
  ERR_error_string_n(e, buf, sizeof(buf));
  return std::string(buf);
}

/** 外部 PSK 回调：OpenSSL 在 TLS1.2 与 TLS1.3 下都会调用它 */
static unsigned int PskClientCb(SSL* ssl, const char* hint, char* identity,
                                unsigned int maxIdentityLen, unsigned char* psk,
                                unsigned int maxPskLen) {
  (void)hint;
  size_t idLen = strlen(PSK_IDENTITY);
  if (maxIdentityLen < idLen + 1 || maxPskLen == 0) {
    return 0;
  }
  memcpy(identity, PSK_IDENTITY, idLen + 1);
  SdTlsConn* conn = static_cast<SdTlsConn*>(SSL_get_app_data(ssl));
  if (!conn || conn->psk.empty()) {
    return 0;
  }
  size_t n = conn->psk.size() < maxPskLen ? conn->psk.size() : maxPskLen;
  memcpy(psk, conn->psk.data(), n);
  return static_cast<unsigned int>(n);
}

/** hex 解码（大小写均可），失败返回 false */
static bool HexDecode(const std::string& hex, std::string* out) {
  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  if (hex.size() % 2 != 0) {
    return false;
  }
  out->clear();
  out->reserve(hex.size() / 2);
  for (size_t i = 0; i + 1 < hex.size(); i += 2) {
    int hi = nibble(hex[i]);
    int lo = nibble(hex[i + 1]);
    if (hi < 0 || lo < 0) {
      return false;
    }
    out->push_back(static_cast<char>((hi << 4) | lo));
  }
  return !out->empty();
}

/** 阻塞 TCP 连接（6 秒超时） */
static int TcpConnect(const std::string& host, int port, std::string* err) {
  addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  addrinfo* res = nullptr;
  int rc = getaddrinfo(host.c_str(), nullptr, &hints, &res);
  if (rc != 0 || res == nullptr) {
    *err = "resolve host failed";
    return -1;
  }
  int fd = -1;
  for (addrinfo* p = res; p != nullptr; p = p->ai_next) {
    sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    memcpy(&addr, p->ai_addr, sizeof(sockaddr_in));
    addr.sin_port = htons(static_cast<uint16_t>(port));
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
      continue;
    }
    timeval tv;
    tv.tv_sec = 6;
    tv.tv_usec = 0;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
      fd = s;
      break;
    }
    close(s);
  }
  freeaddrinfo(res);
  if (fd < 0) {
    *err = "tcp connect failed/timeout";
  }
  return fd;
}

static void ReleaseTsf(const std::shared_ptr<SdTlsConn>& conn) {
  bool expected = false;
  if (conn->tsfReleased.compare_exchange_strong(expected, true) && conn->tsf != nullptr) {
    napi_release_threadsafe_function(conn->tsf, napi_tsfn_release);
  }
}

/** 读线程：SSL_read 循环，事件经 TSF 送回 JS */
static void ReadLoop(std::shared_ptr<SdTlsConn> conn) {
  char buf[64 * 1024];
  while (!conn->closed.load()) {
    int rc = SSL_read(conn->ssl, buf, sizeof(buf));
    if (conn->closed.load()) {
      break;
    }
    if (rc > 0) {
      SdTlsEvent* ev = new SdTlsEvent();
      ev->type = 0;
      ev->data.assign(buf, buf + rc);
      napi_call_threadsafe_function(conn->tsf, ev, napi_tsfn_nonblocking);
      continue;
    }
    int err = SSL_get_error(conn->ssl, rc);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
      continue;  // 读超时唤醒，未关闭则继续
    }
    SdTlsEvent* ev = new SdTlsEvent();
    if (err == SSL_ERROR_ZERO_RETURN) {
      ev->type = 1;
      ev->message = "server closed";
    } else {
      ev->type = 2;
      ev->message = SslErrorText();
    }
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                 "read loop exit: type=%d err=%d msg=%{public}s", ev->type, err, ev->message.c_str());
    napi_call_threadsafe_function(conn->tsf, ev, napi_tsfn_nonblocking);
    break;
  }
  ReleaseTsf(conn);
}

// ---------------- NAPI：tlsConnect ----------------

struct ConnectCtx {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string host;
  int port = 0;
  std::string password;
  int handle = -1;
  std::string error;
};

static void ConnectExecute(napi_env env, void* data) {
  ConnectCtx* ctx = static_cast<ConnectCtx*>(data);
  OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
               "tlsConnect begin host=%{public}s port=%d pwd.len=%zu",
               ctx->host.c_str(), ctx->port, ctx->password.size());

  // PSK = hex_decode(密码 + "1A1A...1A")；密码必须是 Driver Console 显示的十六进制密钥
  std::string psk;
  if (!HexDecode(ctx->password + "1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A", &psk)) {
    ctx->error = "password must be hex (see Driver Console key)";
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "reject: password not hex");
    return;
  }

  SSL_CTX* sctx = SSL_CTX_new(TLS_client_method());
  if (!sctx) {
    ctx->error = "SSL_CTX_new failed";
    return;
  }
  SSL_CTX_set_min_proto_version(sctx, TLS1_2_VERSION);
  SSL_CTX_set_max_proto_version(sctx, TLS1_3_VERSION);
  // TLS1.2 PSK 套件：纯 PSK + ECDHE-PSK 两套都给，
  // 以匹配官方安卓客户端 TLS1_2 模式选定的 0xccac = TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
  SSL_CTX_set_cipher_list(sctx,
                          "PSK-AES128-CBC-SHA:PSK-AES256-CBC-SHA:PSK-AES128-GCM-SHA256:PSK-AES256-GCM-SHA384:"
                          "ECDHE-PSK-CHACHA20-POLY1305:ECDHE-PSK-AES128-GCM-SHA256:ECDHE-PSK-AES256-GCM-SHA384:"
                          "ECDHE-PSK-AES128-CBC-SHA256:ECDHE-PSK-AES256-CBC-SHA384:"
                          "ECDHE-PSK-AES128-CBC-SHA:ECDHE-PSK-AES256-CBC-SHA");
  // TLS1.3 套件用 OpenSSL 默认（含 AES-128-GCM / CHACHA20，与已验证可用的官方客户端一致）
  SSL_CTX_set_ciphersuites(sctx,
                           "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256");
  SSL_CTX_set_verify(sctx, SSL_VERIFY_NONE, nullptr);
  SSL_CTX_set_psk_client_callback(sctx, PskClientCb);

  std::string err;
  int fd = TcpConnect(ctx->host, ctx->port, &err);
  if (fd < 0) {
    SSL_CTX_free(sctx);
    ctx->error = err;
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "tcp connect failed: %{public}s", err.c_str());
    return;
  }
  SSL* ssl = SSL_new(sctx);
  if (!ssl) {
    close(fd);
    SSL_CTX_free(sctx);
    ctx->error = "SSL_new failed";
    return;
  }
  SSL_set_fd(ssl, fd);

  auto conn = std::make_shared<SdTlsConn>();
  conn->psk = psk;
  SSL_set_app_data(ssl, conn.get());
  conn->fd = fd;
  conn->ctx = sctx;
  conn->ssl = ssl;

  if (SSL_connect(ssl) != 1) {
    ctx->error = "TLS handshake failed: " + SslErrorText();
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "handshake failed: %{public}s", ctx->error.c_str());
    SSL_free(ssl);
    SSL_CTX_free(sctx);
    close(fd);
    return;
  }
  const char* ver = SSL_get_version(ssl);
  const SSL_CIPHER* cipher = SSL_get_current_cipher(ssl);
  OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
               "TLS connected: %{public}s %{public}s", ver,
               cipher ? SSL_CIPHER_standard_name(cipher) : "?");

  // 读循环里用短超时轮询，便于退出
  timeval tv;
  tv.tv_sec = 1;
  tv.tv_usec = 0;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

  int id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    id = g_nextId++;
    conn->id = id;
    g_conns[id] = conn;
  }
  ctx->handle = id;
}

static void ConnectComplete(napi_env env, napi_status status, void* data) {
  ConnectCtx* ctx = static_cast<ConnectCtx*>(data);
  if (ctx->handle >= 0) {
    napi_value result;
    napi_create_int32(env, ctx->handle, &result);
    napi_resolve_deferred(env, ctx->deferred, result);
  } else {
    napi_value reason;
    napi_create_string_utf8(env, ctx->error.c_str(), ctx->error.size(), &reason);
    napi_reject_deferred(env, ctx->deferred, reason);
  }
  napi_delete_async_work(env, ctx->work);
  delete ctx;
}

static napi_value TlsConnect(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    return nullptr;
  }
  char host[128] = {0};
  size_t len = 0;
  napi_get_value_string_utf8(env, args[0], host, sizeof(host), &len);
  int32_t port = 0;
  napi_get_value_int32(env, args[1], &port);
  char password[256] = {0};
  napi_get_value_string_utf8(env, args[2], password, sizeof(password), &len);

  ConnectCtx* ctx = new ConnectCtx();
  ctx->host = host;
  ctx->port = port;
  ctx->password = password;

  napi_value promise;
  napi_value name;
  napi_create_string_utf8(env, "tlsConnect", NAPI_AUTO_LENGTH, &name);
  napi_create_promise(env, &ctx->deferred, &promise);
  napi_create_async_work(env, nullptr, name, ConnectExecute, ConnectComplete, ctx, &ctx->work);
  napi_queue_async_work(env, ctx->work);
  return promise;
}

// ---------------- NAPI：tlsStartRead ----------------

static void TlsEventCallJs(napi_env env, napi_value jsCb, void* context, void* data) {
  (void)context;
  SdTlsEvent* ev = static_cast<SdTlsEvent*>(data);
  if (ev == nullptr) {
    return;
  }
  napi_value typeVal;
  napi_create_int32(env, ev->type, &typeVal);
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  if (ev->type == 0) {
    void* bufData = nullptr;
    napi_value buffer;
    napi_create_arraybuffer(env, ev->data.size(), &bufData, &buffer);
    memcpy(bufData, ev->data.data(), ev->data.size());
    napi_value argv[1] = {buffer};
    napi_call_function(env, undefined, jsCb, 1, argv, nullptr);
  } else {
    napi_value msg;
    napi_create_string_utf8(env, ev->message.c_str(), ev->message.size(), &msg);
    napi_value argv[2] = {typeVal, msg};
    napi_call_function(env, undefined, jsCb, 2, argv, nullptr);
  }
  delete ev;
}

static napi_value TlsStartRead(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return nullptr;
  }
  int32_t handle = -1;
  napi_get_value_int32(env, args[0], &handle);
  std::shared_ptr<SdTlsConn> conn;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_conns.find(handle);
    if (it != g_conns.end()) {
      conn = it->second;
    }
  }
  if (!conn || conn->tsf != nullptr) {
    return nullptr;
  }
  napi_value resourceName;
  napi_create_string_utf8(env, "sdTlsRead", NAPI_AUTO_LENGTH, &resourceName);
  napi_create_threadsafe_function(env, args[1], nullptr, resourceName, 64, 1,
                                  nullptr, nullptr, nullptr, TlsEventCallJs,
                                  &conn->tsf);
  napi_ref_threadsafe_function(env, conn->tsf);
  std::thread(ReadLoop, conn).detach();
  return nullptr;
}

// ---------------- NAPI：tlsWrite ----------------

struct WriteCtx {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::shared_ptr<SdTlsConn> conn;
  std::vector<uint8_t> data;
  std::string error;
};

static void WriteExecute(napi_env env, void* data) {
  (void)env;
  WriteCtx* ctx = static_cast<WriteCtx*>(data);
  const uint8_t* p = ctx->data.data();
  size_t remain = ctx->data.size();
  while (remain > 0 && !ctx->conn->closed.load()) {
    int rc = SSL_write(ctx->conn->ssl, p, (int)remain);
    if (rc > 0) {
      p += rc;
      remain -= (size_t)rc;
      continue;
    }
    int err = SSL_get_error(ctx->conn->ssl, rc);
    if (err == SSL_ERROR_WANT_WRITE || err == SSL_ERROR_WANT_READ) {
      continue;
    }
    ctx->error = SslErrorText();
    break;
  }
}

static void WriteComplete(napi_env env, napi_status status, void* data) {
  WriteCtx* ctx = static_cast<WriteCtx*>(data);
  if (ctx->error.empty()) {
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_resolve_deferred(env, ctx->deferred, undefined);
  } else {
    napi_value reason;
    napi_create_string_utf8(env, ctx->error.c_str(), ctx->error.size(), &reason);
    napi_reject_deferred(env, ctx->deferred, reason);
  }
  napi_delete_async_work(env, ctx->work);
  delete ctx;
}

static napi_value TlsWrite(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return nullptr;
  }
  int32_t handle = -1;
  napi_get_value_int32(env, args[0], &handle);
  void* bufData = nullptr;
  size_t bufLen = 0;
  napi_get_arraybuffer_info(env, args[1], &bufData, &bufLen);
  std::shared_ptr<SdTlsConn> conn;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_conns.find(handle);
    if (it != g_conns.end()) {
      conn = it->second;
    }
  }
  if (!conn) {
    return nullptr;
  }
  WriteCtx* ctx = new WriteCtx();
  ctx->conn = conn;
  const uint8_t* bytes = static_cast<const uint8_t*>(bufData);
  ctx->data.assign(bytes, bytes + bufLen);

  napi_value promise;
  napi_value name;
  napi_create_string_utf8(env, "tlsWrite", NAPI_AUTO_LENGTH, &name);
  napi_create_promise(env, &ctx->deferred, &promise);
  napi_create_async_work(env, nullptr, name, WriteExecute, WriteComplete, ctx, &ctx->work);
  napi_queue_async_work(env, ctx->work);
  return promise;
}

// ---------------- NAPI：tlsClose ----------------

struct CloseCtx {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::shared_ptr<SdTlsConn> conn;
};

static void CloseExecute(napi_env env, void* data) {
  (void)env;
  CloseCtx* ctx = static_cast<CloseCtx*>(data);
  ctx->conn->closed.store(true);
  SSL_shutdown(ctx->conn->ssl);  // 尽力而为，失败不处理
  SSL_free(ctx->conn->ssl);
  SSL_CTX_free(ctx->conn->ctx);
  close(ctx->conn->fd);
  std::lock_guard<std::mutex> lock(g_mutex);
  g_conns.erase(ctx->conn->id);
}

static void CloseComplete(napi_env env, napi_status status, void* data) {
  CloseCtx* ctx = static_cast<CloseCtx*>(data);
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  napi_resolve_deferred(env, ctx->deferred, undefined);
  napi_delete_async_work(env, ctx->work);
  delete ctx;
}

static napi_value TlsClose(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) {
    return nullptr;
  }
  int32_t handle = -1;
  napi_get_value_int32(env, args[0], &handle);
  std::shared_ptr<SdTlsConn> conn;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_conns.find(handle);
    if (it != g_conns.end()) {
      conn = it->second;
      g_conns.erase(it);
    }
  }
  if (!conn) {
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
  }
  CloseCtx* ctx = new CloseCtx();
  ctx->conn = conn;
  napi_value promise;
  napi_value name;
  napi_create_string_utf8(env, "tlsClose", NAPI_AUTO_LENGTH, &name);
  napi_create_promise(env, &ctx->deferred, &promise);
  napi_create_async_work(env, nullptr, name, CloseExecute, CloseComplete, ctx, &ctx->work);
  napi_queue_async_work(env, ctx->work);
  return promise;
}

// ---------------- NAPI：tlsVersion（诊断用） ----------------

static napi_value TlsVersion(napi_env env, napi_callback_info info) {
  (void)info;
  const char* v = OpenSSL_version(OPENSSL_VERSION);
  napi_value result;
  napi_create_string_utf8(env, v, strlen(v), &result);
  return result;
}

// ---------------- 模块注册 ----------------

EXTERN_C_START
static napi_value ModuleInit(napi_env env, napi_value exports) {
  napi_property_descriptor props[] = {
    {"tlsConnect", nullptr, TlsConnect, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"tlsStartRead", nullptr, TlsStartRead, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"tlsWrite", nullptr, TlsWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"tlsClose", nullptr, TlsClose, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"tlsVersion", nullptr, TlsVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
  return exports;
}
EXTERN_C_END

static napi_module sectlsModule = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = nullptr,
  .nm_register_func = ModuleInit,
  .nm_modname = "sectls",
  .nm_priv = nullptr,
  .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterSectlsModule(void) {
  napi_module_register(&sectlsModule);
}
