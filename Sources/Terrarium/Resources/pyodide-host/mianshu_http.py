"""mianshu_http —— 沙箱内同步 HTTP 改道原生 URLSession 代理。

解决两个硬限制：
1. WASM 无 socket：requests/urllib3/http.client 的 TCP 连接无法建立
2. 浏览器网络栈丢 Referer、受 CORS 限制：新浪行情等站点拒答

原理（协议级通用，不绑定任何站点）：
- http.client.HTTPConnection.request/getresponse 被替换：请求编码进
  pyodide-local://net?u=..&r=.. 代理 URL，由宿主 SchemeHandler 用
  URLSession 原样发出（Referer/UA 等头原生可设，重定向由 URLSession
  自动跟随）
- 等待用「同步 XMLHttpRequest」：阻塞的是 WebContent 进程主线程，
  宿主 SchemeHandler 在 App 进程交付响应，跨进程无死锁
- 响应统一为 JSON 信封 {"status","headers","bodyB64"}（固定 200 交付），
  不依赖同步 XHR 的字符集行为
- Python 侧重组为标准 http.client.HTTPResponse，urllib3/requests
  零感知，超时由宿主统一控制（60s）

局限（v1）：请求体仅支持 str/bytes；直连 http.client 原始 API
（putrequest/putheader 风格）不支持。
"""

import base64
import io
import json as _json
from http.client import HTTPConnection, HTTPSConnection, HTTPResponse

import js

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
    """把 cls 的 request/getresponse 替换为代理实现。

    urllib3 的 HTTPConnection 继承自 http.client.HTTPConnection，
    在 HTTPConnection 上打补丁即可覆盖 requests/urllib/urllib3 全家。
    """

    def request(self, method, url, body=None, headers={}, *, encode_chunked=False):
        host = self.host
        port = self.port
        default_port = 443 if scheme == "https" else 80
        if url.startswith("http://") or url.startswith("https://"):
            abs_url = url
            netloc = host if port == default_port else f"{host}:{port}"
        else:
            netloc = host if port == default_port else f"{host}:{port}"
            abs_url = f"{scheme}://{netloc}{url or '/'}"

        if body is None:
            body_bytes = b""
        elif isinstance(body, (bytes, bytearray)):
            body_bytes = bytes(body)
        elif isinstance(body, str):
            body_bytes = body.encode("utf-8")
        else:
            raise NotImplementedError("mianshu_http: 仅支持 str/bytes 请求体")

        hdrs = {str(k): str(v) for k, v in (headers or {}).items()}
        lower = {k.lower() for k in hdrs}
        if "host" not in lower:
            hdrs["Host"] = netloc
        if "accept-encoding" not in lower:
            # 明文优先：gzip 由服务端尊重该头时才出现，http.client 不解压
            hdrs["Accept-Encoding"] = "identity"
        if body_bytes and "content-length" not in lower:
            hdrs["Content-Length"] = str(len(body_bytes))

        method_upper = str(method).upper()
        status, resp_headers, resp_body = _proxy_fetch(
            method_upper, abs_url, hdrs, body_bytes or None
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
                lines.append(f"{key}: ".encode("latin-1") + str(value).encode("utf-8", "replace"))
        raw = b"\r\n".join(lines) + b"\r\n\r\n" + resp_body

        self._ms_pending_raw = raw
        self._ms_pending_method = method_upper

    def getresponse(self):
        raw = getattr(self, "_ms_pending_raw", None)
        if raw is None:
            raise ConnectionError("mianshu_http: request/getresponse 状态不匹配")
        self._ms_pending_raw = None
        resp = HTTPResponse(_FakeSocket(raw), method=getattr(self, "_ms_pending_method", "GET"))
        resp.begin()
        return resp

    cls.request = request
    cls.getresponse = getresponse


def install():
    """启用代理（幂等）。bootstrap 阶段调用一次。"""
    _install_class(HTTPConnection, "http")
    _install_class(HTTPSConnection, "https")
