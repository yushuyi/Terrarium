"""mianshu_pkg —— 用户脚本内安装 PyPI 包并自动持久化（面书 iOS）。

背景：pyodide 用户脚本（顶层 await 上下文）里直接调
``await micropip.install(...)`` 有两个缺口（2026-09-26 真机实测）：
1. micropip 把包装进 pyodide 自己的 purelib（/lib/python3.13/
   site-packages），而持久化镜像只收录 /persist/site-packages；
2. micropip 不输出持久化镜像 marker，冷启动后包丢失（SNOW_LOST）。

终端 ``pip install`` 命令通道（ms_pip_code.py）的做法是：安装后把新包
按 RECORD 文件清单从 purelib 合并（复制）进 /persist/site-packages，
再把该目录打成镜像、经 host.js 的 ``__TERRARIUM_PERSIST_B64__:`` 通道
存入 Documents/pyodide_persist.zip。本模块把同一机制开放给用户脚本：

    # %runtime pyodide
    from mianshu_pkg import install_packages
    await install_packages("text-unidecode")
    from text_unidecode import unidecode

    # 多个/钉版本：
    await install_packages(["mammoth==1.12.2", "openpyxl==3.1.5"])

说明：
- 与终端 pip 通道同一持久化镜像，安装后**离线可用、冷启动保留**；
- 锁包已由 bundle 提供同版本的包不会复制进 persist（persist 副本会遮蔽
  bundle 的 WASM .so、引发 SystemError）——它们直接 import 即可；
- 仍受 pyodide 能力边界约束：未移植 WASM 的 C 扩展（onnxruntime/
  pypdfium2 等）装不上；
- persist=False 时只装当前运行时、不合并不打包（临时试用）。
"""

import base64
import importlib.metadata as _md
import io
import os
import pathlib
import shutil
import zipfile

__all__ = ["install_packages", "snapshot_persist", "merge_into_persist"]

_PERSIST = pathlib.Path("/persist/site-packages")


def _norm(name):
    return name.lower().replace("-", "_")


def _snapshot_dists():
    """安装前/后 dist 快照：{规范名: distribution 对象}。"""
    out = {}
    for dist in _md.distributions():
        name = dist.metadata and dist.metadata["Name"]
        if name:
            out[_norm(name)] = dist
    return out


def _lockfile_versions():
    """锁包 {规范名: 版本}，取自 host.js 注入的 window 映射。

    用于跳过「bundle 已提供同版本」的包——其 WASM .so 经 bundle 专属
    构建与 dynlib 注册，复制第三方 wheel 进 persist 会遮蔽并 SystemError。
    """
    try:
        import js
        entries = js.Object.entries(js.window.__MS_LOCKFILE_FILES__)
    except Exception:
        return {}
    out = {}
    for entry in entries:
        fname = str(entry[1])
        parts = fname.split("-")
        if len(parts) >= 2:
            out[_norm(str(entry[0]))] = parts[1]
    return out


async def install_packages(packages, *, persist=True):
    """安装一个或多个 PyPI 包；默认合并进 /persist 并写持久化镜像。

    参数：
        packages: 需求字符串（"name==version"）或字符串列表；
        persist: True=合并+打包镜像（跨启动保留），False=仅当前运行时。
    返回：micropip.install 的返回值（通常为 None）。
    """
    import micropip

    if isinstance(packages, str):
        packages = [packages]
    before = _snapshot_dists()
    result = await micropip.install(list(packages))
    if persist:
        merge_into_persist(before)
        snapshot_persist()
    return result


def merge_into_persist(before):
    """把安装后新增/版本变化的包从 purelib 按 RECORD 合并进 /persist。

    逻辑与 ms_pip_code.py 复制段一致：
    - 同版本未变化、bundle 锁包同版本、源已在 /persist 的跳过；
    - 升级/降级先按旧 RECORD 清理旧文件与旧 dist-info；
    - RECORD 条目（dist.files）相对 site-packages，逐个复制并做越界防护。
    返回复制的文件数。
    """
    _PERSIST.mkdir(parents=True, exist_ok=True)
    persist_real = str(_PERSIST.resolve())
    lock_vers = _lockfile_versions()
    copied = 0
    for norm, dist in _snapshot_dists().items():
        old = before.get(norm)
        if old is not None and old.version == dist.version:
            continue
        if lock_vers.get(norm) == dist.version:
            continue
        src_root = pathlib.Path(dist.locate_file("")).resolve()
        sr = str(src_root)
        if sr == persist_real or sr.startswith(persist_real + "/"):
            continue
        if old is not None:
            for record_file in (old.files or []):
                try:
                    (_PERSIST / str(record_file)).unlink()
                except OSError:
                    pass
            try:
                old_info = _PERSIST / pathlib.Path(str(old.locate_file(""))).name
                if old_info.name.endswith(".dist-info") and old_info.is_dir():
                    shutil.rmtree(old_info, ignore_errors=True)
            except OSError:
                pass
        for record_file in (dist.files or []):
            try:
                src = dist.locate_file(record_file)
                if not src.is_file():
                    continue
                dst = _PERSIST / str(record_file)
                rs = str(dst.resolve())
                if rs != persist_real and not rs.startswith(persist_real + "/"):
                    continue
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dst)
                copied += 1
            except Exception:
                pass
    return copied


def snapshot_persist():
    """把 /persist/site-packages 打成镜像并输出持久化 marker。

    host.js 捕获 stdout 中 ``__TERRARIUM_PERSIST_B64__:`` 开头的行，
    随 runResult 回传宿主存入 pyodide_persist.zip。镜像内路径以
    /persist 为根（site-packages/...），与 bootstrap 解包恢复的口径
    一致（参照 ms_pip_code.py 镜像段）。返回打包文件数。
    """
    if not os.path.isdir(_PERSIST):
        return 0
    buf = io.BytesIO()
    count = 0
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(_PERSIST):
            for name in files:
                path = os.path.join(root, name)
                zf.write(path, os.path.relpath(path, "/persist"))
                count += 1
    if count:
        print("__TERRARIUM_PERSIST_B64__:"
              + base64.b64encode(buf.getvalue()).decode())
    return count
