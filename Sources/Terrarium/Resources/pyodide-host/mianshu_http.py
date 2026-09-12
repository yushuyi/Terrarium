"""mianshu_http —— 沙箱内同步 HTTP 改道原生 URLSession 代理。

解决两个硬限制：
1. WASM 无 socket：requests/urllib3/http.client 的 TCP 连接无法建立
2. 浏览器网络栈丢 Referer、受 CORS 限制：新浪行情等站点拒答

原理（协议级通用，不绑定任何站点）：
- 补丁点下沉到 http.client 的五个原语 putrequest/putheader/
  _send_output/send/getresponse。urllib3 的 HTTPConnection 覆写了
  request()（putrequest→putheader→endheaders→send 链），不调用
  super().request()，所以只有原语层能同时覆盖 requests/urllib/裸
  http.client 全部路径；响应统一 JSON 信封 {"status","headers",
  "bodyB64"}（固定 200 交付），重组为标准 HTTPResponse 返回
- urllib3 在 emscripten 平台 import 时会自注入浏览器 XHR 连接类
  （contrib/emscripten，受 CORS 限制），install() 时换回标准连接类
- 等待用「同步 XMLHttpRequest」：阻塞的是 WebContent 进程主线程，
  宿主 SchemeHandler 在 App 进程交付响应，跨进程无死锁
- 超时由宿主统一控制（60s）；重定向由 URLSession 自动跟随

局限（v1）：异步库（httpx/aiohttp）不走 http.client，不覆盖；
请求体经 send 累积，理论支持任意流式 body。
"""

import base64
import io
import json as _json
from http.client import HTTPConnection, HTTPResponse

import js

try:
    from http.client import HTTPSConnection as _StdHTTPSConnection
except ImportError:
    # ssl 包未加载时 http.client 不定义 HTTPSConnection；
    # install() 会以替身类兜底（TLS 由原生 URLSession 完成）
    _StdHTTPSConnection = None

_ms_https_cls = None  # 实际生效的 https 连接类（供 urllib3 还原用）

_PROXY_BASE = "pyodide-local://net?"


def _b64url(data: bytes) -> str:
    """URL 安全 base64（去填充），配合 Swift 侧 b64url 解码。"""
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


class _ProxyError(OSError):
    """代理链路错误（宿主网络失败/参数无效），区别于目标站点的 HTTP 错误。"""


def _proxy_fetch(method, abs_url, headers, body):
    """同步执行代理请求。返回 (status:int, headers:list[(k,v)], body:bytes)。"""
    from urllib.parse import quote

    spec = {"method": method, "headers": headers}
    if body:
        spec["bodyB64"] = base64.b64encode(body).decode()
    query = (
        "u=" + quote(_b64url(abs_url.encode()), safe="")
        + "&r=" + quote(_b64url(_json.dumps(spec).encode()), safe="")
    )
    xhr = js.XMLHttpRequest.new()
    xhr.open("GET", _PROXY_BASE + query, False)  # 同步模式：阻塞至响应到达
    xhr.send()
    if xhr.status == 0:
        raise _ProxyError("代理请求失败（宿主无响应）")
    try:
        envelope = _json.loads(xhr.responseText)
    except Exception as exc:
        raise _ProxyError(f"代理响应解析失败: {exc}") from exc
    status = int(envelope.get("status") or 0)
    if status == 0:
        raise _ProxyError("代理请求失败: " + str(envelope.get("error", "未知错误")))
    headers_out = [(str(k), str(v)) for k, v in (envelope.get("headers") or {}).items()]
    body_out = base64.b64decode(envelope.get("bodyB64") or "")
    return status, headers_out, body_out


class _FakeSocket:
    """给 HTTPResponse 提供 makefile 接口的内存字节流。"""

    def __init__(self, raw: bytes):
        self._file = io.BytesIO(raw)

    def makefile(self, mode, buffering=None, **_):
        return self._file


def _install_class(cls, scheme):
    """把 cls 的底层原语替换为代理实现。

    urllib3.connection.HTTPConnection 继承自 http.client.HTTPConnection
    且不覆写这些原语（只覆写 request/getresponse 的上层编排），因此在
    基类打补丁即可让 requests/urllib/urllib3 全部改道。
    """

    def putrequest(self, method, url, skip_host=False, skip_accept_encoding=False):
        self._ms_method = str(method).upper()
        self._ms_url = url
        self._ms_headers = []
        self._ms_body = bytearray()
        self._ms_headers_done = False
        if not skip_host:
            self.putheader("Host", self._ms_netloc())
        if not skip_accept_encoding:
            # 明文优先：http.client 不解压，gzip 会破坏 body 组装
            self.putheader("Accept-Encoding", "identity")

    def putheader(self, header, *values):
        if not hasattr(self, "_ms_headers"):
            raise ConnectionError("mianshu_http: putheader 必须先于 putrequest 调用")
        self._ms_headers.append((str(header), ", ".join(str(v) for v in values)))

    def _send_output(self, message_body=None, encode_chunked=False):
        # 原实现在此拼响应头字节流并 send——我们改为只标记头结束；
        # message_body（http.client 自带 request 路径）在此收进 body
        self._ms_headers_done = True
        if message_body is None:
            return
        if isinstance(message_body, str):
            self._ms_body.extend(message_body.encode("utf-8"))
        elif isinstance(message_body, (bytes, bytearray)):
            self._ms_body.extend(bytes(message_body))
        else:
            # 文件/可迭代 body：逐块读取
            while True:
                try:
                    chunk = message_body.read(65536)
                except AttributeError:
                    chunk = None
                    try:
                        chunk = next(iter(message_body))
                    except StopIteration:
                        pass
                if not chunk:
                    break
                self.send(chunk if isinstance(chunk, bytes) else str(chunk).encode("utf-8"))

    def send(self, data):
        # urllib3 在 endheaders 后经 send 逐块送 body；头阶段字节已由
        # putheader 结构化保存，这里只收 body
        if getattr(self, "_ms_headers_done", False) and data:
            self._ms_body.extend(bytes(data))

    def getresponse(self):
        method = getattr(self, "_ms_method", None)
        if method is None:
            raise ConnectionError("mianshu_http: getresponse 必须先于 putrequest 调用")
        url = self._ms_url or "/"
        if url.startswith("http://") or url.startswith("https://"):
            abs_url = url
        else:
            abs_url = f"{scheme}://{self._ms_netloc()}{url if url.startswith('/') else '/' + url}"

        status, resp_headers, resp_body = _proxy_fetch(
            method, abs_url, self._ms_headers, bytes(self._ms_body) or None
        )

        # 重组原始响应字节流，交给标准 HTTPResponse 解析
        # （Content-Length/chunked/HEAD 无体等语义全部复用标准实现）
        lines = [f"HTTP/1.1 {status} MS-PROXY".encode("latin-1")]
        if not resp_headers:
            resp_headers = [("Content-Length", "0")]
        for key, value in resp_headers:
            try:
                lines.append(f"{key}: {value}".encode("latin-1"))
            except UnicodeEncodeError:
                lines.append(f"{key}: ".encode("latin-1") + value.encode("utf-8", "replace"))
        raw = b"\r\n".join(lines) + b"\r\n\r\n" + resp_body

        resp = HTTPResponse(_FakeSocket(raw), method=method)
        resp.begin()
        return resp

    cls.putrequest = putrequest
    cls.putheader = putheader
    cls._send_output = _send_output
    cls.send = send
    cls.getresponse = getresponse
    cls._ms_netloc = lambda self: (
        self.host
        if self.port in (80, 443, None)
        else f"{self.host}:{self.port}"
    )


def _restore_urllib3():
    """换回 urllib3 的标准连接类。

    urllib3/__init__.py 在 emscripten 平台 import 时自动执行
    inject_into_urllib3()，把连接池的 ConnectionCls 换成浏览器 XHR
    实现（受 CORS 限制）。connectionpool 模块命名空间还保留着注入前
    导入的原始连接类（其基类已被本模块打补丁），换回即可。
    """
    try:
        import urllib3.connectionpool as _cp

        _cp.HTTPConnectionPool.ConnectionCls = _cp.HTTPConnection
        if _ms_https_cls is not None:
            # ssl 缺失时 urllib3 的 HTTPSConnection 是 DummyConnection，
            # 不能作为连接类；换成本模块的替身
            _cp.HTTPSConnectionPool.ConnectionCls = _ms_https_cls
        else:
            _cp.HTTPSConnectionPool.ConnectionCls = _cp.HTTPSConnection
    except Exception:
        pass
    # https 池 _validate_conn 会在发请求前触发真 socket 的 connect()
    # ——沙箱无 socket，连接由原生代理完成，置为空操作
    try:
        _cp = __import__("urllib3.connectionpool", fromlist=["HTTPSConnection"])
        _cp.HTTPSConnection.connect = lambda self, *a, **k: None
    except Exception:
        pass


def install():
    """启用代理（幂等）。bootstrap 阶段调用一次。"""
    global _ms_https_cls
    _install_class(HTTPConnection, "http")
    if _StdHTTPSConnection is not None:
        _install_class(_StdHTTPSConnection, "https")
        _ms_https_cls = _StdHTTPSConnection
    else:
        class _MSHTTPSConnection(HTTPConnection):
            """ssl 缺失时的 https 替身：TLS 由原生 URLSession 完成。"""
            default_port = 443

        _install_class(_MSHTTPSConnection, "https")
        _ms_https_cls = _MSHTTPSConnection
    _restore_urllib3()
