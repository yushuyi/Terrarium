"""mianshu_http —— 沙箱内同步 HTTP 改道原生 URLSession 代理。

解决两个硬限制：
1. WASM 无 socket：requests/urllib3/http.client 的 TCP 连接无法建立
2. 浏览器网络栈丢 Referer、受 CORS 限制：新浪行情等站点拒答

原理（协议级通用，不绑定任何站点）：
- http.client 侧：putrequest/putheader 完全不动（保留状态机与自动头
  语义），只拦截三个「触达 socket」的点：
    _send_output：不发 socket，改为捕获缓冲中的请求行+请求头
    send        ：不发 socket，只累积请求体（urllib3 分块 body 由此到达）
    getresponse ：组代理 URL → 同步 XHR → 原生 URLSession → 响应重组为
                  标准 HTTPResponse
- urllib3 2.x 侧：emscripten 平台 import 时会自注入浏览器 XHR 连接类
  （受 CORS 限制），restore 换回标准连接类；其 getresponse 含无守卫的
  self.sock.settimeout（sock 恒为 None），以复刻版替换（去 sock 访问）
- 等待用「同步 XMLHttpRequest」：阻塞的是 WebContent 进程主线程，
  宿主 SchemeHandler 在 App 进程交付响应，跨进程无死锁
- 响应统一 JSON 信封 {"status","headers","bodyB64"}（固定 200 交付），
  不依赖同步 XHR 的字符集行为；超时经 spec.timeoutMs 透传宿主
  （缺省 60s）；重定向由 URLSession 自动跟随（requests 侧
  allow_redirects=False 不生效，见实施方案已知限制）

局限（v1）：异步库（httpx/aiohttp）不走 http.client，不覆盖。
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
_DEFAULT_TIMEOUT_S = 60.0


def _b64url(data: bytes) -> str:
    """URL 安全 base64（去填充），配合 Swift 侧 b64url 解码。"""
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


class _ProxyError(OSError):
    """代理链路错误（宿主网络失败/参数无效），区别于目标站点的 HTTP 错误。"""


def _proxy_fetch(method, abs_url, headers, body, timeout_s):
    """同步执行代理请求。返回 (status:int, headers:list[(k,v)], body:bytes)。"""
    from urllib.parse import quote

    spec = {"method": method, "headers": headers}
    if timeout_s and timeout_s > 0:
        spec["timeoutMs"] = int(timeout_s * 1000)
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


def _conn_timeout_s(self):
    """连接对象上的超时（urllib3 会设 float；裸 http.client 可能是对象）。"""
    t = getattr(self, "timeout", None)
    if isinstance(t, (int, float)) and 0 < t < 3600:
        return float(t)
    return _DEFAULT_TIMEOUT_S


def _install_class(cls, scheme):
    """拦截 cls 触达 socket 的三个点（putrequest/putheader 保持原语义）。"""

    def _send_output(self, message_body=None, encode_chunked=False):
        # 原实现在此拼头字节流并 send——我们改为捕获后等 getresponse 发代理
        self._ms_req_lines = list(getattr(self, "_buffer", []))
        del self._buffer[:]
        self._ms_body = bytearray()
        if message_body is None:
            return
        if isinstance(message_body, str):
            self._ms_body.extend(message_body.encode("utf-8"))
        elif isinstance(message_body, (bytes, bytearray)):
            self._ms_body.extend(bytes(message_body))
        else:
            # 文件/可迭代 body：逐块读入
            while True:
                if hasattr(message_body, "read"):
                    chunk = message_body.read(65536)
                else:
                    try:
                        chunk = next(iter(message_body))
                    except StopIteration:
                        chunk = None
                if not chunk:
                    break
                self._ms_body.extend(chunk if isinstance(chunk, bytes) else str(chunk).encode("utf-8"))

    def send(self, data):
        # urllib3 在 endheaders 后经 send 逐块送 body，在此累积
        if data:
            if not hasattr(self, "_ms_body"):
                self._ms_body = bytearray()
            self._ms_body.extend(bytes(data))

    def getresponse(self):
        lines = getattr(self, "_ms_req_lines", None)
        if not lines:
            raise ConnectionError("mianshu_http: 无待发请求")
        req_line = lines[0].decode("latin-1")
        parts = req_line.split(" ")
        method = parts[0].upper()
        path = parts[1] if len(parts) > 1 else "/"
        headers = []
        for raw in lines[1:]:
            line = raw.decode("latin-1").rstrip("\r\n")
            if ": " in line:
                key, value = line.split(": ", 1)
                headers.append((key, value))

        # 绝对 URL：优先 Host 头（原版 putrequest 已按语义生成），退回连接属性。
        # IPv6 字面量补方括号；其余交给原生 URL 解析（IDN 由 NSURL 容错）
        host_header = next((v for k, v in headers if k.lower() == "host"), None)
        if host_header:
            netloc = host_header
        elif ":" in (self.host or "") and not (self.host or "").startswith("["):
            netloc = f"[{self.host}]:{self.port}" if self.port not in (80, 443, None) else f"[{self.host}]"
        else:
            netloc = self.host if self.port in (80, 443, None) else f"{self.host}:{self.port}"
        if "://" in path:
            abs_url = path
        else:
            abs_url = f"{scheme}://{netloc}{path if path.startswith('/') else '/' + path}"

        status, resp_headers, resp_body = _proxy_fetch(
            method, abs_url, headers, bytes(self._ms_body) or None, _conn_timeout_s(self)
        )

        # 重组原始响应字节流，交给标准 HTTPResponse 解析。响应头已由宿主
        # 剔除 Transfer-Encoding / 失真的 Content-Length / Content-Encoding
        # （body 恒为解 chunk、未透明解压的原始字节），无头时读至 EOF。
        out_lines = [f"HTTP/1.1 {status} MS-PROXY".encode("latin-1")]
        for key, value in resp_headers:
            try:
                out_lines.append(f"{key}: {value}".encode("latin-1"))
            except UnicodeEncodeError:
                out_lines.append(f"{key}: ".encode("latin-1") + value.encode("utf-8", "replace"))
        raw = b"\r\n".join(out_lines) + b"\r\n\r\n" + resp_body

        resp = HTTPResponse(_FakeSocket(raw), method=method)
        resp.begin()
        return resp

    cls._send_output = _send_output
    cls.send = send
    cls.getresponse = getresponse


def _patch_urllib3_connection_cls():
    """urllib3 2.x 的 HTTPConnection.getresponse 含无守卫的
    self.sock.settimeout（沙箱内 sock 恒为 None，必炸 AttributeError）。

    按内置版本（2.5.0）逐字复刻该函数、去掉 sock 访问，替换之；
    try/except 防未来版本漂移（漂移时 requests 链路失效但不崩）。
    """
    try:
        import urllib3.connection as _uconn
        from urllib3._collections import HTTPHeaderDict as _HeaderDict
        from urllib3.response import HTTPResponse as _U3Response
    except Exception:
        return

    def _u3_getresponse(self):
        if getattr(self, "_response_options", None) is None:
            from urllib3.exceptions import ResponseNotReady

            raise ResponseNotReady()
        resp_options = self._response_options
        self._response_options = None
        httplib_response = super(_uconn.HTTPConnection, self).getresponse()
        headers = _HeaderDict(httplib_response.msg.items())
        return _U3Response(
            body=httplib_response,
            headers=headers,
            status=httplib_response.status,
            version=httplib_response.version,
            version_string=getattr(self, "_http_vsn_str", "HTTP/?"),
            reason=httplib_response.reason,
            preload_content=resp_options.preload_content,
            decode_content=resp_options.decode_content,
            original_response=httplib_response,
            enforce_content_length=resp_options.enforce_content_length,
            request_method=resp_options.request_method,
            request_url=resp_options.request_url,
        )

    try:
        _uconn.HTTPConnection.getresponse = _u3_getresponse
    except Exception:
        pass


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
        import urllib3.connectionpool as _cp2

        _cp2.HTTPSConnection.connect = lambda self, *a, **k: None
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


def ensure():
    """每次脚本执行前调用（幂等、廉价）。

    bootstrap 时 urllib3 尚未加载，restore 无事可做；用户脚本 import
    触发 urllib3 装载时会重新执行 inject_into_urllib3，把连接类换回
    浏览器 XHR 实现。此处在 loadPackagesFromImports 之后、用户代码
    之前再还原一次。
    """
    if "urllib3" in __import__("sys").modules:
        _patch_urllib3_connection_cls()
        _restore_urllib3()
