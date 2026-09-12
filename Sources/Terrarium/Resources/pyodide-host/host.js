// Terrarium Pyodide host
//
// Loaded inside a hidden WKWebView. Bridges Swift ↔ Pyodide:
//   • runPython(id, code)         — execute user code, post result back
//   • installPackage(id, pkg)     — micropip.install with progress
//   • uninstallPackage(id, pkg)   — best-effort uninstall (rm site-package)
//   • listPackages(id)            — enumerate installed packages
//   • clearPackageCache(id)       — wipe IndexedDB-backed cache
//
// All responses are sent via window.webkit.messageHandlers.terrariumPyodide.postMessage.

let pyodide = null;
let pyodideReady = false;
let stdoutBuf = "";
let stderrBuf = "";
let progressBuf = [];
// 当前正在执行的 runPython 调用 id——stdout/stderr 回调据此做流式转发
let currentRunId = null;
// 启动期警告（ssl/代理注入失败等）——首跑时经 stderr 流出，避免静默
let bootWarnings = [];

// Persistent storage path inside Pyodide's emscripten FS. We mount IDBFS
// here so installed packages survive WebView reloads (and thus app
// launches). Site-packages, downloaded wheels, anything micropip wrote.
const PERSIST_DIR = "/persist";

function post(payload) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.terrariumPyodide) {
    window.webkit.messageHandlers.terrariumPyodide.postMessage(payload);
  }
}

async function syncFS(populate) {
  return new Promise((resolve, reject) => {
    pyodide.FS.syncfs(populate, (err) => (err ? reject(err) : resolve()));
  });
}

async function bootstrap() {
  try {
    pyodide = await loadPyodide({
      // 离线模式：运行时与常用包（numpy/pandas/matplotlib 闭包 + micropip）
      // 全部经 pyodide-local:// 从 App Bundle 伺服，由
      // PyodideSchemeHandler 提供文件，不走 CDN。版本由
      // Scripts/fetch-pyodide.sh 锁定（0.29.4），与 bundle 内容一致。
      indexURL: "pyodide-local://bundle/",
      stdout: (text) => {
        stdoutBuf += text + "\n";
        // 流式转发给 Swift（__TERRARIUM_IMG__ 标记行留给 runResult，
        // 图像渲染走专门通道，不刷终端）
        if (currentRunId && !text.startsWith("__TERRARIUM_IMG_PNG_B64__:")) {
          post({ kind: "stdout", id: currentRunId, line: text });
        }
      },
      stderr: (text) => {
        stderrBuf += text + "\n";
        if (currentRunId) {
          post({ kind: "stderr", id: currentRunId, line: text });
        }
      },
    });

    // Mount IDBFS at /persist and pull any previously-synced packages
    // off disk. `populate=true` loads from IndexedDB into the FS.
    pyodide.FS.mkdir(PERSIST_DIR);
    pyodide.FS.mount(pyodide.FS.filesystems.IDBFS, {}, PERSIST_DIR);
    await syncFS(true);

    // Make sure /persist/site-packages exists, then put it on sys.path
    // before any user import resolution happens.
    const sitePackages = PERSIST_DIR + "/site-packages";
    if (!pyodide.FS.analyzePath(sitePackages).exists) {
      pyodide.FS.mkdir(sitePackages);
      await syncFS(false);
    }
    pyodide.runPython(`
import sys
if "${sitePackages}" not in sys.path:
    sys.path.insert(0, "${sitePackages}")
`);

    // Pre-load micropip — it's tiny (~150 KB) and we use it for every
    // `%pip install`. Without this, the first install pays a load tax.
    await pyodide.loadPackage("micropip");

    // Override micropip's install target to /persist/site-packages so
    // installed wheels survive the FS reset on reload.
    pyodide.runPython(`
import micropip
import micropip._compat as _mc

# Force micropip to write into the persistent dir. Without this, wheels
# land in the in-memory site-packages and vanish on reload.
import sys
_target = "${sitePackages}"
if _target not in sys.path:
    sys.path.insert(0, _target)
`);

    // ssl：http.client.HTTPSConnection 的依赖包。沙箱内不做真 TLS
    // （由原生 URLSession 完成），但类结构必须存在，否则 urllib3 降级
    // 为 DummyConnection 且 mianshu_http 注入失败
    try {
      await pyodide.loadPackage("ssl");
    } catch (e) {
      bootWarnings.push("ssl 包加载失败，https 请求将不可用");
      console.warn("[mianshu_http] ssl 包加载失败:", e);
    }

    // mianshu_http：把 http.client 改道原生网络代理（同步桥）。
    // requests/urllib/urllib3 零改动可用；Referer/CORS 限制由原生侧绕过。
    // 注入失败不阻断 bootstrap（纯标准库脚本不需要它）。
    try {
      const modResp = await fetch("pyodide-local://host/mianshu_http.py");
      if (!modResp.ok) throw new Error("fetch 失败: " + modResp.status);
      const modText = await modResp.text();
      pyodide.FS.writeFile("/lib/python3.13/site-packages/mianshu_http.py", modText, { encoding: "utf8" });
      await pyodide.runPythonAsync("import mianshu_http; mianshu_http.install()");
    } catch (e) {
      bootWarnings.push("mianshu_http 注入失败，联网脚本不可用: " + String(e && e.message || e));
      console.warn("[mianshu_http] 注入失败:", e);
    }

    pyodideReady = true;
    post({ kind: "ready", version: pyodide.version });
  } catch (err) {
    // JavaScriptCore 的 err.stack 不含 message，必须显式拼上才能定位问题
    const detail = err instanceof Error
      ? (err.message || String(err)) + "\n" + (err.stack || "")
      : String(err);
    post({ kind: "bootstrapFailed", error: detail });
  }
}

function resetBuffers() {
  stdoutBuf = "";
  stderrBuf = "";
  progressBuf = [];
}

async function runPython(id, code) {
  if (!pyodideReady) {
    post({ kind: "runResult", id, stdout: "", stderr: "Pyodide not yet ready", exception: null, exitCode: -1, durationMs: 0 });
    return;
  }
  resetBuffers();
  currentRunId = id;
  if (bootWarnings.length) {
    for (const w of bootWarnings) {
      post({ kind: "stderr", id, line: "[pyodide] " + w });
    }
    bootWarnings = [];
  }
  const t0 = performance.now();
  let exception = null;
  let exitCode = 0;

  const loadFromLockfile = async () => {
    // 按 import 自动加载 lockfile 内的包：bundle 内的 wheel 经
    // pyodide-local:// 离线伺服；未打包的包会 404——捕获后放行，
    // 让用户代码以明确的 ModuleNotFoundError 失败（再由 micropip 兜底）
    try {
      await pyodide.loadPackagesFromImports(code, {
        messageCallback: (m) => {
          if (currentRunId) post({ kind: "stderr", id: currentRunId, line: String(m) });
        },
      });
    } catch (loadErr) {
      if (currentRunId) {
        post({ kind: "stderr", id: currentRunId, line: "[pyodide] 自动加载依赖失败: " + String(loadErr && loadErr.message || loadErr) });
      }
    }
  };

  const runUser = async () => {
    await loadFromLockfile();
    await pyodide.runPythonAsync(code);
    // Jupyter-style auto-show: if the user's code created matplotlib
    // figures but never called `.show()` or saved them, auto-render
    // each figure to a PNG and emit it via the terrarium_show marker.
    // This is the same convention Jupyter / IPython uses for plt.plot()
    // calls at the end of a cell — it's what users expect to happen.
    await autoShowMatplotlibFigures();
  };

  try {
    try {
      await runUser();
    } catch (runErr) {
      // micropip 纯包兜底：缺失模块不在离线 bundle（如 tushare）时，
      // 从 PyPI 拉纯 wheel 安装（需网络），destination 指向 /persist
      // 使安装跨启动保留；锁表内包的失败是「真缺包」，不在此列也无妨
      // （micropip 会失败并回传原始错误）。
      const msg = String(runErr && runErr.message || runErr);
      const m = /ModuleNotFoundError: No module named '([^']+)'/.exec(msg);
      if (!m) throw runErr;
      const missing = m[1].split(".")[0].replace(/-/g, "_");
      if (currentRunId) {
        post({ kind: "stderr", id: currentRunId, line: "[pyodide] " + missing + " 不在离线 bundle，尝试 micropip 安装（需网络）…" });
      }
      try {
        await pyodide.loadPackage("micropip");
        // destination 不被旧版 micropip 支持时退化为默认位置（仅本次会话有效）
        await pyodide.runPythonAsync(
          "import micropip\n" +
          "try:\n" +
          "    await micropip.install('" + missing + "', destination='/persist/site-packages')\n" +
          "except TypeError:\n" +
          "    await micropip.install('" + missing + "')"
        );
      } catch (installErr) {
        if (currentRunId) {
          post({ kind: "stderr", id: currentRunId, line: "[pyodide] micropip 安装失败: " + String(installErr && installErr.message || installErr) });
        }
        throw runErr; // 原始 ModuleNotFoundError 才是用户要看的错误
      }
      if (currentRunId) {
        post({ kind: "stderr", id: currentRunId, line: "[pyodide] " + missing + " 安装完成，重新执行脚本" });
      }
      await runUser(); // 二次失败直接向外抛，错误信息真实
    }
  } catch (e) {
    exception = String(e && e.message || e);
    exitCode = 1;
  } finally {
    currentRunId = null;
  }
  const durationMs = Math.round(performance.now() - t0);
  // Sync any FS changes the user code made to IDBFS so they persist.
  try { await syncFS(false); } catch (_) {}
  post({
    kind: "runResult",
    id,
    stdout: stdoutBuf,
    stderr: stderrBuf,
    exception,
    exitCode,
    durationMs,
  });
}

/// Render every open matplotlib figure to a PNG and print it with the
/// `terrarium_show` marker so the runner's View tab picks them up.
/// No-op if matplotlib was never imported in this run.
///
/// We render through `FigureCanvasAgg` directly instead of relying on
/// `Figure.savefig`. Pyodide ships matplotlib with the
/// `module://matplotlib_pyodide.html5_canvas_backend` backend by default,
/// and that backend's canvas needs a real `<canvas>` element in the DOM —
/// which we don't have, since the WKWebView is headless. Going through
/// Agg directly sidesteps the active backend entirely and produces a
/// PNG every time `plt.plot(...)` created a figure, regardless of
/// whether the user called `plt.show()`.
async function autoShowMatplotlibFigures() {
  try {
    await pyodide.runPythonAsync(`
import sys as _sys
if 'matplotlib' in _sys.modules or 'matplotlib.pyplot' in _sys.modules:
    _errs = []
    try:
        import matplotlib.pyplot as _plt
        from matplotlib.backends.backend_agg import FigureCanvasAgg as _AggCanvas
        import io as _io, base64 as _b64
        _nums = list(_plt.get_fignums())
        for _num in _nums:
            try:
                _fig = _plt.figure(_num)
                _canvas = _AggCanvas(_fig)
                _buf = _io.BytesIO()
                _canvas.print_png(_buf)
                _buf.seek(0)
                _encoded = _b64.b64encode(_buf.read()).decode('ascii')
                print(f"__TERRARIUM_IMG_PNG_B64__:{_encoded}")
            except Exception as _fe:
                _errs.append(f"figure {_num}: {_fe!r}")
        _plt.close('all')
    except Exception as _e:
        _errs.append(repr(_e))
    if _errs:
        # Surface to stderr so the user sees WHY their plot didn't show.
        # The runner's Console tab pipes stderr in red.
        import sys as __sys
        for _msg in _errs:
            print(f"[terrarium] auto-show failed — {_msg}", file=__sys.stderr)
`);
  } catch (jsErr) {
    // Last-resort JS-side catch. Surface to stderrBuf so the Swift side
    // sees something other than silence when this path explodes.
    stderrBuf += "[terrarium] auto-show JS error: " + String(jsErr) + "\n";
  }
}

async function installPackage(id, pkg) {
  if (!pyodideReady) {
    post({ kind: "installResult", id, pkg, ok: false, error: "Pyodide not yet ready" });
    return;
  }

  post({ kind: "installProgress", id, line: `Collecting ${pkg}` });

  try {
    // PREFERRED PATH — pyodide.loadPackage. Works for any package in
    // Pyodide's official index (numpy, pandas, matplotlib, scipy,
    // sklearn, etc.), supports a `messageCallback` for live progress,
    // and handles transitive deps in parallel. Streams lines like
    // "Loading matplotlib, numpy, contourpy, …" and "Loaded matplotlib".
    let loadedViaIndex = false;
    try {
      await pyodide.loadPackage(pkg, {
        messageCallback: (msg) => {
          post({ kind: "installProgress", id, line: `  ${msg}` });
        },
        errorCallback: (msg) => {
          post({ kind: "installProgress", id, line: `  ${msg}` });
        },
      });
      loadedViaIndex = true;
    } catch (loadErr) {
      // loadPackage throws for packages not in the Pyodide-built index
      // — those need micropip's PyPI resolver. We fall through silently
      // and try micropip next.
      const m = String(loadErr && loadErr.message || loadErr);
      // If the error is anything OTHER than "not in index", re-raise.
      // 404 视同「不在本地 bundle」——离线模式下未打包的包走 micropip 兜底。
      if (!/Can't find a package/i.test(m) && !/not found/i.test(m) && !/404/.test(m)) {
        throw loadErr;
      }
      post({ kind: "installProgress", id, line: `  Package not in local bundle, falling back to PyPI…` });
    }

    // FALLBACK PATH — micropip.install for arbitrary PyPI packages.
    // micropip doesn't have a `messageCallback`, so we monkey-patch
    // Python's stdout to stream lines back as they're printed. Then
    // we run micropip with verbose=True so it prints per-dep progress.
    if (!loadedViaIndex) {
      // Register a JS function the Python streaming-stdout can call.
      pyodide.globals.set("__terrarium_pip_emit", (line) => {
        post({ kind: "installProgress", id, line: `  ${String(line)}` });
      });
      await pyodide.runPythonAsync(`
import sys, micropip
class _TerrariumStreamingStdout:
    def __init__(self):
        self._buffer = ""
    def write(self, s):
        self._buffer += s
        while "\\n" in self._buffer:
            line, self._buffer = self._buffer.split("\\n", 1)
            if line.strip():
                __terrarium_pip_emit(line)
        return len(s)
    def flush(self):
        if self._buffer.strip():
            __terrarium_pip_emit(self._buffer)
        self._buffer = ""

_old_stdout = sys.stdout
sys.stdout = _TerrariumStreamingStdout()
try:
    await micropip.install(${JSON.stringify(pkg)}, keep_going=True, verbose=True)
finally:
    try: sys.stdout.flush()
    except Exception: pass
    sys.stdout = _old_stdout
`);
      // Clean up the JS hook.
      pyodide.globals.delete("__terrarium_pip_emit");
    }

    // After install, look up the installed version for the success line.
    let version = "unknown";
    try {
      const v = pyodide.runPython(`
import importlib.metadata as _md
try: _v = _md.version(${JSON.stringify(pkg)})
except Exception: _v = ""
_v
`);
      if (v) version = v;
    } catch (_) {}

    try { await syncFS(false); } catch (_) {}

    post({ kind: "installProgress", id, line: `Successfully installed ${pkg}-${version}` });
    post({ kind: "installResult", id, pkg, ok: true, version });
  } catch (err) {
    const msg = String(err && err.message || err);
    post({ kind: "installProgress", id, line: `ERROR: ${msg.split("\n")[0]}` });
    post({ kind: "installResult", id, pkg, ok: false, error: msg });
  }
}

async function uninstallPackage(id, pkg) {
  if (!pyodideReady) {
    post({ kind: "uninstallResult", id, pkg, ok: false, error: "Pyodide not yet ready" });
    return;
  }
  try {
    await pyodide.runPythonAsync(`
import importlib.metadata as _md, shutil, sys, sysconfig, os
from pathlib import Path

pkg_name = ${JSON.stringify(pkg)}
target = pkg_name.lower().replace("-", "_")

# Same dirs listPackages scans — Pyodide's own site-packages PLUS our
# IDBFS mount. We have to clean both so an uninstall actually frees the
# bytes the user expects (whichever dir the package landed in).
search_dirs = []
for key in ("purelib", "platlib"):
    p = sysconfig.get_paths().get(key)
    if p and p not in search_dirs: search_dirs.append(p)
persist = "${PERSIST_DIR}/site-packages"
if persist not in search_dirs:
    search_dirs.append(persist)

# Try micropip first — it's the cleanest path, handles dependencies, and
# updates micropip's own bookkeeping. Falls through to manual cleanup
# below if micropip can't find or uninstall the package.
try:
    import micropip
    if hasattr(micropip, "uninstall"):
        micropip.uninstall(pkg_name)
except Exception:
    pass

# Manual cleanup: scan each site-packages dir for the package's files
# and remove them. Match by normalized name (PyPI normalizes - and _).
for site in search_dirs:
    if not os.path.isdir(site):
        continue
    for entry in os.listdir(site):
        low = entry.lower().replace("-", "_")
        if low == target or low.startswith(target + "-"):
            full = os.path.join(site, entry)
            try:
                if os.path.isdir(full):
                    shutil.rmtree(full, ignore_errors=True)
                else:
                    os.remove(full)
            except Exception:
                pass

# Drop any importlib-cached refs so a subsequent import doesn't pull
# the now-deleted module from the meta-path cache.
for mod in list(sys.modules.keys()):
    if mod == target or mod.startswith(target + "."):
        sys.modules.pop(mod, None)
`);
    try { await syncFS(false); } catch (_) {}
    post({ kind: "uninstallResult", id, pkg, ok: true });
  } catch (err) {
    post({ kind: "uninstallResult", id, pkg, ok: false, error: String(err) });
  }
}

async function listPackages(id) {
  if (!pyodideReady) {
    post({ kind: "listResult", id, packages: [] });
    return;
  }
  try {
    // Pyodide's `loadPackage` installs into its own internal site-
    // packages dir (`sysconfig.get_paths()["purelib"]`), NOT into our
    // /persist IDBFS mount. micropip with no `target` argument also
    // lands there. So we have to scan BOTH locations to find every
    // user-installed package.
    //
    // We also filter out packages that ship as part of Pyodide's base
    // distribution (the ~30 things loaded at bootstrap — micropip,
    // distutils, etc.) so the list only shows packages the user
    // actually triggered an install for. We do that by reading the
    // `name` from each dist-info's `INSTALLER` file when present —
    // packages installed by `loadPackage` get an INSTALLER of
    // "pyodide.loadPackage", which is exactly what we want to surface.
    const json = await pyodide.runPythonAsync(`
import importlib.metadata as _md, json, os, sys, sysconfig
from pathlib import Path

# Every site-packages dir Python knows about (Pyodide's + our IDBFS mount).
search_dirs = []
for key in ("purelib", "platlib"):
    p = sysconfig.get_paths().get(key)
    if p and p not in search_dirs: search_dirs.append(p)
persist = "${PERSIST_DIR}/site-packages"
if persist not in search_dirs:
    search_dirs.append(persist)

# Packages we never want to surface as "user-installed" — these come
# with the Pyodide WASM runtime itself and the user didn't install them.
BUILTIN_BASELINE = {
    "distutils", "pip", "setuptools", "wheel", "pkg_resources",
    # micropip is the package installer; we load it during bootstrap.
    # Listing it would be confusing.
    "micropip",
}

result = []
seen = set()
for d in search_dirs:
    if not os.path.isdir(d):
        continue
    for entry in sorted(os.listdir(d)):
        if not entry.endswith(".dist-info"):
            continue
        try:
            dist = _md.PathDistribution(Path(d) / entry)
            name = (dist.metadata.get("Name") or
                    entry.rsplit("-", 1)[0]).strip()
            key = name.lower()
            if key in seen:
                continue
            if key in BUILTIN_BASELINE:
                continue
            seen.add(key)

            size = 0
            for f in dist.files or []:
                try: size += dist.locate_file(f).stat().st_size
                except Exception: pass

            result.append({
                "name": name,
                "version": dist.version or "—",
                "size": size,
            })
        except Exception:
            pass
json.dumps(result)
`);
    post({ kind: "listResult", id, packages: JSON.parse(json) });
  } catch (err) {
    post({ kind: "listResult", id, packages: [], error: String(err) });
  }
}

async function clearPackageCache(id) {
  try {
    await pyodide.runPythonAsync(`
import shutil, os
persist = "${PERSIST_DIR}/site-packages"
if os.path.isdir(persist):
    for entry in os.listdir(persist):
        full = os.path.join(persist, entry)
        try:
            if os.path.isdir(full):
                shutil.rmtree(full, ignore_errors=True)
            else:
                os.remove(full)
        except Exception:
            pass
`);
    try { await syncFS(false); } catch (_) {}
    post({ kind: "clearResult", id, ok: true });
  } catch (err) {
    post({ kind: "clearResult", id, ok: false, error: String(err) });
  }
}

window.terrariumRunPython = runPython;
window.terrariumInstallPackage = installPackage;
window.terrariumUninstallPackage = uninstallPackage;
window.terrariumListPackages = listPackages;
window.terrariumClearPackageCache = clearPackageCache;

bootstrap();
