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
let persistB64 = null; // pip 流程输出的持久化镜像（随 runResult 回传）
// 工作区快照桥（I-4）：run 后收集的 MEMFS Documents 变更（b64 JSON），
// 随 runResult 回传 Swift 写回宿主
let wsWriteB64 = null;

// Persistent storage path inside Pyodide's emscripten FS. Installed packages
// land here in-session; across launches they come back via the native mirror
// (Swift injects Documents/pyodide_persist.zip, see seedPersistMirror).
const PERSIST_DIR = "/persist";

function post(payload) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.terrariumPyodide) {
    window.webkit.messageHandlers.terrariumPyodide.postMessage(payload);
  }
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
        // pip 持久化镜像：捕获后随 runResult 回传，不进终端流（行长达 MB 级）
        if (text.startsWith("__TERRARIUM_PERSIST_B64__:")) {
          persistB64 = text.slice("__TERRARIUM_PERSIST_B64__:".length).trim();
          return;
        }
        // 工作区收集 marker：捕获后随 runResult 回传，不进终端流
        if (text.startsWith("__MS_WS_WRITE_B64__:")) {
          wsWriteB64 = text.slice("__MS_WS_WRITE_B64__:".length).trim();
          return;
        }
        stdoutBuf += text + "\n";
        // 流式转发给 Swift（__TERRARIUM_IMG__ 标记行留给 runResult，
        // 图像渲染走专门通道，不刷终端）
        if (currentRunId && !text.startsWith("__TERRARIUM_IMG_PNG_B64__:") &&
            !text.startsWith("__MS_SAVEFIG_PNG_B64__:")) {
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

    // /persist 为普通 MEMFS 目录：已安装包的文件由 pip 流程复制至此，
    // 跨启动经「原生镜像」恢复——WebKit 对自定义 scheme 页面的 IndexedDB
    // 是临时的（IDBFS 方案实测同容器冷启动即丢，且无任何报错），不可依赖。
    pyodide.FS.mkdir(PERSIST_DIR);
    // 工作区快照桥就绪标志（I-4）：Swift 注入快照且 host.js restore
    // 成功后置 true——guard 据此决定是否打"内存态"警告。js 模块对
    // window 缺失属性抛 AttributeError，必须先初始化
    window.__MS_WS_READY__ = false;

    // 等待 Swift 注入持久化镜像（window.__MS_PERSIST_B64__，见
    // PyodideBridge.seedPersistMirror）。旧宿主/无镜像时 15s 超时放行。
    // __MS_PERSIST_WAIT__ 是 Swift 轮询的「页面 JS 已就绪」信号。
    window.__MS_PERSIST_WAIT__ = true;
    try {
      await new Promise((resolve) => {
        if (window.__MS_PERSIST_SEEDED__) return resolve();
        const started = performance.now();
        const t = setInterval(() => {
          if (window.__MS_PERSIST_SEEDED__ || performance.now() - started > 15000) {
            clearInterval(t);
            resolve();
          }
        }, 100);
      });
    } catch (_) {}
    if (!window.__MS_PERSIST_SEEDED__) {
      // 仅异常时告警：Swift 侧轮询/注入未在窗口内置位
      bootWarnings.push("持久化镜像注入等待超时（宿主未置 SEEDED）");
    }
    if (window.__MS_PERSIST_B64__) {
      try {
        await pyodide.runPythonAsync(
          "import base64, io, zipfile\n" +
          "_b64 = __import__('js').window.__MS_PERSIST_B64__ or ''\n" +
          "_z = zipfile.ZipFile(io.BytesIO(base64.b64decode(_b64)))\n" +
          "_n = len(_z.namelist())\n" +
          "_z.extractall('/persist')\n" +
          "print('[pyodide] 已从原生镜像恢复 ' + str(_n) + ' 个持久化文件')\n"
        );
      } catch (e) {
        bootWarnings.push("持久化镜像恢复失败: " + String(e));
      } finally {
        // 释放 JS 侧大字符串（恢复已完成/已失败，内存不再需要）
        window.__MS_PERSIST_B64__ = null;
      }
    }

    // Make sure /persist/site-packages exists, then put it on sys.path
    // before any user import resolution happens.
    const sitePackages = PERSIST_DIR + "/site-packages";
    if (!pyodide.FS.analyzePath(sitePackages).exists) {
      pyodide.FS.mkdir(sitePackages);
    }
    pyodide.runPython(`
import sys
if "${sitePackages}" not in sys.path:
    sys.path.insert(0, "${sitePackages}")
`);

    // Pre-load micropip — it's tiny (~150 KB) and we use it for every
    // `%pip install`. Without this, the first install pays a load tax.
    await pyodide.loadPackage("micropip", { messageCallback: () => {}, errorCallback: () => {} });

    // ssl：http.client.HTTPSConnection 的依赖包。沙箱内不做真 TLS
    // （由原生 URLSession 完成），但类结构必须存在，否则 urllib3 降级
    // 为 DummyConnection 且 mianshu_http 注入失败
    try {
      await pyodide.loadPackage("ssl", { messageCallback: () => {}, errorCallback: () => {} });
    } catch (e) {
      bootWarnings.push("ssl 包加载失败，https 请求将不可用");
      console.warn("[mianshu_http] ssl 包加载失败:", e);
    }

    // lockfile 映射注入（独立于 mianshu_http）：micropip 对发行版包拼
    // indexURL 相对 URL（pyodide-local://bundle/<file_name>），bundle 未
    // 打包的 wheel（scipy 等）404——pip 安装兜底据此把 URL 重定向到官
    // 方 CDN；deps 供安装侧做依赖闭包展开（BFS 收集全部 URL 一次装）。
    // 单独 try：mianshu_http 拉取失败不得连坐 lockfile 映射
    try {
      const lockResp = await fetch("pyodide-local://bundle/pyodide-lock.json");
      if (lockResp.ok) {
        const lock = await lockResp.json();
        const files = {};
        const deps = {};
        for (const [name, info] of Object.entries(lock.packages || {})) {
          files[name] = info.file_name || "";
          deps[name] = info.depends || [];
        }
        window.__MS_LOCKFILE_FILES__ = files;
        window.__MS_LOCKFILE_DEPS__ = deps;
        window.__MS_PYODIDE_VERSION__ = pyodide.version;
        // bundle 加载链路自检（一次性）：lockfile 包显式 loadPackage 是否
        // 可用。结果进 bootWarnings 随首次 run 上报——loadPackagesFromImports
        // 对 lockfile 包静默跳过时的关键观测点（真机实测缺口）
        try {
          await pyodide.loadPackage("matplotlib", {
            messageCallback: () => {},
            errorCallback: (m) => bootWarnings.push("selftest loadPackage(matplotlib) errorCallback: " + m),
          });
          bootWarnings.push("selftest loadPackage(matplotlib) OK");
        } catch (e) {
          bootWarnings.push("selftest loadPackage(matplotlib) EXC: " + String(e && e.message || e));
        }
      }
    } catch (e) {
      bootWarnings.push("lockfile 映射注入失败，CDN 兜底不可用: " + String(e && e.message || e));
      console.warn("[pyodide] lockfile 映射注入失败:", e);
    }

    // mianshu_http：把 http.client 改道原生网络代理（同步桥）。
    // requests/urllib/urllib3 零改动可用；Referer/CORS 限制由原生侧绕过。
    // 注入失败不阻断 bootstrap（纯标准库脚本不需要它）。
    try {
      const modResp = await fetch("pyodide-local://host/mianshu_http.py");
      if (!modResp.ok) throw new Error("fetch 失败: " + modResp.status);
      const modText = await modResp.text();
      // site-packages 路径经 sysconfig 取（Python 升级 3.14 不失效）
      const siteDir = pyodide.runPython(
        "import sysconfig; sysconfig.get_paths()['purelib']"
      );
      pyodide.FS.writeFile(siteDir + "/mianshu_http.py", modText, { encoding: "utf8" });
      await pyodide.runPythonAsync("import mianshu_http; mianshu_http.install()");
    } catch (e) {
      bootWarnings.push("mianshu_http 注入失败，联网脚本不可用: " + String(e && e.message || e));
      console.warn("[mianshu_http] 注入失败:", e);
    }

    // 运行时环境统一：HOME 固化为容器根（与原生 CPython 的
    // PythonBridge.m setenv 对齐）。pyodide 默认 HOME=/home/pyodide
    // 是 MEMFS 虚拟路径，`~` 展开跨运行时漂移（测试计划 I-3）。
    // 同时对指向容器根的写模式 open 打告警：pyodide FS 是纯 MEMFS
    // （IDBFS 实测同容器冷启动即丢），文件写入报成功但宿主永远
    // 不可见，必须让静默丢失变有声。
    try {
      const docRoot = window.__MS_DOCROOT__ || "";
      if (docRoot) {
        const docRootLit = JSON.stringify(docRoot);
        // /tmp → Documents/tmp 映射（I-8）：与原生 CPython 的 TMPDIR 语义
        // 对齐——第一期 T13（python 写 /tmp 落 Documents/tmp）走原生路由
        // 通过，Pyodide 路由下 /tmp 是调用内独立临时区，与 shell/read_file
        // 交换数据的用法静默失效。symlink 让 pyodide 的 /tmp 写直接落宿主
        try {
          pyodide.FS.mkdirTree(docRoot + "/Documents/tmp");
          try {
            // 已是正确链接则跳过；MEMFS 自带 /tmp 是普通目录（readlink 抛错）
            const linked = pyodide.FS.readlink("/tmp");
            if (linked !== docRoot + "/Documents/tmp") {
              bootWarnings.push("pyodide /tmp 已存在且非预期链接: " + linked);
            }
          } catch (linkErr) {
            try { pyodide.FS.rmdir("/tmp"); } catch (rmErr) {}
            try {
              pyodide.FS.symlink(docRoot + "/Documents/tmp", "/tmp");
            } catch (symErr) {
              // symlink 失败时兜底重建普通目录，避免 /tmp 比修复前更糟
              try { pyodide.FS.mkdir("/tmp"); } catch (mkErr) {}
              bootWarnings.push("pyodide /tmp 映射失败: " + String(symErr));
            }
          }
        } catch (tmpErr) {
          bootWarnings.push("pyodide /tmp 目录创建失败: " + String(tmpErr));
        }
        await pyodide.runPythonAsync(
          "import os, builtins as _msb, sys as _mssys\n" +
          "os.environ['HOME'] = " + JSON.stringify(docRoot) + "\n" +
          // cwd 对齐 Documents 根：emscripten 的 FS.chdir 在 boot 时用默认
          // HOME(/home/pyodide) 已执行，env.HOME 后置修改不影响 cwd，
          // 相对路径 open 会落在 /home/pyodide 下（实测 O-4 Errno 44）
          "os.chdir(" + JSON.stringify(docRoot) + " + '/Documents')\n" +
          "_ms_orig_open = _msb.open\n" +
          "def _ms_guarded_open(file, *a, **k):\n" +
          "    try:\n" +
          "        _p = file if isinstance(file, str) else getattr(file, '__fspath__', lambda: '')()\n" +
          "    except Exception:\n" +
          "        _p = ''\n" +
          "    _mode = a[0] if a else 'r'\n" +
          "    _ws_ready = bool(getattr(__import__('js').window, '__MS_WS_READY__', False))\n" +
          "    _in_docs = _p.startswith(" + docRootLit + " + '/Documents/')\n" +
          "    if isinstance(_p, str) and isinstance(_mode, str) and _p.startswith(" + docRootLit + ") and any(c in _mode for c in 'wax+') and (not _in_docs or not _ws_ready) and not getattr(_msb, '_ms_mem_warned', False):\n" +
          "        _msb._ms_mem_warned = True\n" +
          "        print('⚠️ pyodide 运行时在 Documents 之外写文件为内存态（App 重启即丢，多为库缓存可忽略）；需要持久化请写到 ~/Documents/ 下', file=_mssys.stderr)\n" +
          "    return _ms_orig_open(file, *a, **k)\n" +
          "_msb.open = _ms_guarded_open"
        );
      }
    } catch (e) {
      bootWarnings.push("HOME 固化/写入告警注入失败: " + String(e && e.message || e));
      console.warn("[pyodide] 环境统一注入失败:", e);
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
  persistB64 = null;
}

async function runPython(id, code) {
  if (!pyodideReady) {
    post({ kind: "runResult", id, stdout: "", stderr: "Pyodide not yet ready", exception: null, exitCode: -1, durationMs: 0 });
    return;
  }
  resetBuffers();
  if (currentRunId !== null) {
    // 重入保护：与收集 marker 的全局单值语义配套，拒绝并发执行
    post({ kind: "runResult", id, stdout: "", stderr: "", exception: "另一个 Pyodide 执行仍在进行，已拒绝并发运行", exitCode: 1, durationMs: 0 });
    return;
  }
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
    // 让用户代码以明确的 ModuleNotFoundError 失败（Mac 语义：宿主不自动安装，
    // 由用户显式 pip install）
    // persist 包依赖解析（真机实测缺口）：loadPackagesFromImports 只扫
    // 用户代码顶层 import，persist 里的纯 py 包（如 tushare，不在
    // lockfile）会被跳过——其内部依赖（如 pandas/numpy，在 lockfile）永
    // 远不会被自动加载，冷启动首跑必 ModuleNotFoundError。此处补一环：
    // 识别用户 import 的 persist 包，读其 dist-info/METADATA 的
    // Requires-Dist，与 lockfile 求交后 loadPackage（幂等、离线、全 bundle）
    try {
      const persistDeps = new Set();
      const pkgLoadErrors = new Set();
      const fsEntries = pyodide.FS.readdir("/persist/site-packages").filter(
        (e) => e.endsWith(".dist-info")
      );
      const imported = new Set();
      for (const m of code.matchAll(/^\s*(?:import|from)\s+([A-Za-z_][\w.]*)/gm)) {
        imported.add(m[1].split(".")[0].toLowerCase());
      }
      for (const name of imported) {
        const di = fsEntries.find(
          (e) => e.toLowerCase().startsWith(name + "-") || e.toLowerCase().replace(/_/g, "-").startsWith(name.replace(/_/g, "-") + "-")
        );
        if (!di) continue;
        try {
          const meta = pyodide.FS.readFile(
            "/persist/site-packages/" + di + "/METADATA",
            { encoding: "utf8" }
          );
          for (const line of meta.split("\n")) {
            if (!line.startsWith("Requires-Dist:")) continue;
            const dep = line.slice(14).trim().split(/[ ;<>=!\[]/)[0];
            if (dep) persistDeps.add(dep.toLowerCase().replace(/_/g, "-"));
          }
        } catch (_) {}
      }
      // 逐个 try-catch：bundle 里有的（pandas/numpy/lxml/bs4/requests 等）
      // loadPackage 成功走离线 wheel；bundle 没有的（websocket-client 等）
      // loadPackage 报错被跳过，由 persist 副本或用户侧 pip 兜底。
      // 不用 pyodide.lockfile 对象做白名单：JS 侧该属性不可靠（实测为
      // undefined），交集恒空会让解析整环失效。
      // DEP_ALIASES：PyPI 占位/简写名 → Pyodide lockfile 包名。真机实测
      // tushare 声明 Requires-Dist: bs4，而发行版包名是 beautifulsoup4，
      // 直接 loadPackage("bs4") 找不到包被静默跳过导致 import bs4 失败。
      const DEP_ALIASES = {
        "bs4": "beautifulsoup4",
        "yaml": "pyyaml",
        "dateutil": "python-dateutil",
        "cv2": "opencv-python",
        "sklearn": "scikit-learn",
        "crypto": "pycryptodome",
        "attr": "attrs",
      };
      for (const dep of persistDeps) {
        const canonical = DEP_ALIASES[dep] || dep;
        if (pyodide.loadedPackages[canonical] || pyodide.loadedPackages[dep]) continue;
        try {
          await pyodide.loadPackage(canonical, {
            messageCallback: () => {},
            // 本地 404 的包（如 persist 里的 scipy 及其依赖）会触发
            // errorCallback——不再全静默：收集后上报，保留排查线索
            //（bundle 伺服/lockfile 映射问题的唯一观测点）
            errorCallback: (msg) => pkgLoadErrors.add(String(msg)),
          });
        } catch (err) {
          pkgLoadErrors.add(String(err && err.message || err));
        }
      }
      if (pkgLoadErrors.size && currentRunId) {
        post({
          kind: "stderr",
          id: currentRunId,
          line: "[pyodide] lockfile 依赖 loadPackage 失败: " + [...pkgLoadErrors].join(" | "),
        });
      }
    } catch (persistErr) {
      if (currentRunId)
        post({ kind: "stderr", id: currentRunId, line: "[pyodide] persist 依赖解析失败: " + String(persistErr && persistErr.message || persistErr) });
    }
    try {
      // 加载进度（Loading/Loaded）不上屏：必须显式传空回调——不传时
      // pyodide 退回默认 console.log，经 WebView console 捕获转成
      // stdout（绿色）上屏；失败仍由外层 catch 与后续
      // ModuleNotFoundError 明确暴露
      const pkgImportErrors = new Set();
      // 加载前后对比：区分「pyodide 没尝试加载」（数量不变且 errors 空）
      // 与「尝试了但失败」（errors 非空）——lockfile 自动加载缺口排查
      const loadedBefore = Object.keys(pyodide.loadedPackages || {}).length;
      await pyodide.loadPackagesFromImports(code, {
        messageCallback: () => {},
        // errorCallback 也须静默：bundle 未打包的 lockfile 包（如 pip 装
        // 进 persist 的 scipy）会连带 404 其声明依赖，红字杂音误导用户；
        // 真正的失败由用户代码的 ModuleNotFoundError 明确暴露。
        // 但不再丢线索：收集后上报一条汇总（bundle 伺服排查观测点）
        errorCallback: (msg) => pkgImportErrors.add(String(msg)),
      });
      const loadedAfter = Object.keys(pyodide.loadedPackages || {}).length;
      if (currentRunId) {
        post({
          kind: "stderr",
          id: currentRunId,
          line: "[pyodide] 自动加载对比: " + loadedBefore + "→" + loadedAfter +
            " 包, importErrors=" + pkgImportErrors.size,
        });
      }
      if (pkgImportErrors.size && currentRunId) {
        post({
          kind: "stderr",
          id: currentRunId,
          line: "[pyodide] 按依赖自动加载失败: " + [...pkgImportErrors].join(" | "),
        });
      }
    } catch (loadErr) {
      if (currentRunId) {
        post({ kind: "stderr", id: currentRunId, line: "[pyodide] 自动加载依赖失败: " + String(loadErr && loadErr.message || loadErr) });
      }
    }
  };

  // 工作区快照恢复（I-4）：Swift 在 run 前注入的 Documents 快照写到
  // MEMFS 容器根绝对路径（HOME 已固化，open 即命中），manifest 落
  // /persist 供 run 后 diff 收集。幂等：无 b64 时零开销跳过
  const WS_RESTORE_SRC = [
    "import json as _msj, os as _mso, base64 as _msb",
    "_root = __import__('js').window.__MS_DOCROOT__ or ''",
    "if _root:",
    "    _ws = _msj.loads(__import__('js').window.__MS_WS_B64__ or '[]')",
    "    _keep = set(e['p'] for e in _ws)",
    "    _docs = _mso.path.join(_root, 'Documents')",
    "    if _mso.path.isdir(_docs):",
    "        for _dp, _dn, _fn in _mso.walk(_docs, topdown=False):",
    "            for _f in _fn:",
    "                _p = _mso.path.join(_dp, _f)",
    "                if _p[len(_root):].lstrip('/') not in _keep:",
    "                    try: _mso.remove(_p)",
    "                    except OSError: pass",
    "            for _d in _dn:",
    "                try: _mso.rmdir(_mso.path.join(_dp, _d))",
    "                except OSError: pass",
    "    _mf = {}",
    "    for _e in _ws:",
    "        _p = _mso.path.join(_root, _e['p'])",
    "        _mso.makedirs(_mso.path.dirname(_p), exist_ok=True)",
    "        open(_p, 'wb').write(_msb.b64decode(_e['d']))",
    "        try:",
    "            _st = _mso.stat(_p)",
    "            _mf[_e['p']] = [_st.st_size, int(_st.st_mtime)]",
    "        except OSError: pass",
    "    _msj.dump(_mf, open('/persist/.ms_ws_manifest.json', 'w'))",
    "__import__('js').window.__MS_WS_B64__ = None",
  ].join("\n");
  // 工作区收集（I-4）：对比注入 manifest 与当前 MEMFS 容器根子树，
  // 新增/变更/删除打包回传；manifest 更新为当前状态供下次 diff。
  // size+mtime 双字段对比，等长内容变更也能检出
  const WS_COLLECT_SRC = [
    "import os as _o, json as _j, base64 as _b",
    "_root = __import__('js').window.__MS_DOCROOT__ or ''",
    "if _root:",
    "    try: _mf = _j.load(open('/persist/.ms_ws_manifest.json'))",
    "    except Exception: _mf = {}",
    "    _cur, _w = {}, {}",
    "    for _dp, _dn, _fn in _o.walk(_root):",
    "        for _f in _fn:",
    "            _p = _o.path.join(_dp, _f)",
    "            _r = _p[len(_root):].lstrip('/')",
    "            if not _r.startswith('Documents/'):",
    "                continue",
    "            try: _st = _o.stat(_p)",
    "            except Exception: continue",
    "            _sig = [_st.st_size, int(_st.st_mtime)]",
    "            _cur[_r] = _sig",
    "            if _r not in _mf or _mf[_r] != _sig:",
    "                try: _w[_r] = _b.b64encode(open(_p, 'rb').read()).decode()",
    "                except Exception: pass",
    "    _d = [_r for _r in _mf if _r not in _cur]",
    "    _j.dump(_cur, open('/persist/.ms_ws_manifest.json', 'w'))",
    "    if _w or _d:",
    "        print('__MS_WS_WRITE_B64__:' + _b.b64encode(_j.dumps({'w': _w, 'd': _d}).encode()).decode())",
  ].join("\n");

  const runUser = async () => {
    // 工作区快照恢复须在一切用户可见执行之前
    if (window.__MS_WS_B64__) {
      try {
        // 独立 globals（review m6）：临时变量不落用户命名空间
        const wsGlobals = pyodide.toPy({});
        try { await pyodide.runPythonAsync(WS_RESTORE_SRC, { globals: wsGlobals }); }
        finally { wsGlobals.destroy(); }
        // 对账会删 MEMFS 空目录，/tmp symlink 的目标必须在此后重建
        if (window.__MS_DOCROOT__) {
          try { pyodide.FS.mkdirTree(window.__MS_DOCROOT__ + "/Documents/tmp"); }
          catch (e) { console.warn("[pyodide] /tmp 目标目录重建失败:", e); }
        }
        window.__MS_WS_READY__ = true;
      } catch (e) { console.warn("[pyodide] 工作区恢复失败:", e); }
    }
    await loadFromLockfile();
    // urllib3 在用户 import 时会被再次注入 emscripten 连接类，执行前还原
    try {
      await pyodide.runPythonAsync("import mianshu_http; mianshu_http.ensure()");
    } catch (_) {}
    await ensureSavefigPatched();
    // 已保存 figure 集合按次清空：close('all') 后 number 从 1 复用，
    // 残留会让新 run 的同号图被 auto-show 误跳过
    try { await pyodide.runPythonAsync("globals().get('_ms_saved_figs', set()).clear()"); } catch (_) {}
    await pyodide.runPythonAsync(code);
    // Jupyter-style auto-show: if the user's code created matplotlib
    // figures but never called `.show()` or saved them, auto-render
    // each figure to a PNG and emit it via the terrarium_show marker.
    // This is the same convention Jupyter / IPython uses for plt.plot()
    // calls at the end of a cell — it's what users expect to happen.
    await autoShowMatplotlibFigures();
  };

  try {
    // Mac 语义：缺包不自动安装。ModuleNotFoundError 等错误原样抛出，
    // 由终端呈现真实 traceback（exit 1）；补装依赖走显式 `pip install`
    // 命令（TerminalBridge 把 pip 转发到本运行时的 micropip）。
    await runUser();
  } catch (e) {
    exception = String(e && e.message || e);
    exitCode = 1;
    // CLI 语义：脚本 raise SystemExit(N) 是正常退出通道（含 0），不是
    // 异常。Pyodide 把 Python 异常统一转成 PythonError（message=traceback），
    // SystemExit 的退出码只能从 traceback 尾行 "SystemExit: N" 提取。
    // 必须锚定尾行：链式 traceback（except SystemExit: raise ...）中部
    // 出现的 SystemExit 不是最终异常，首匹配会误提取并吞掉真实错误。
    const sysExit = /(?:^|\n)SystemExit: ([^\n]*)\s*$/.exec(exception || "");
    if (sysExit) {
      const c = sysExit[1];
      if (c === "None" || c === "") {
        exitCode = 0;
      } else if (/^-?\d+$/.test(c)) {
        exitCode = parseInt(c, 10);
      } else {
        exitCode = 1; // SystemExit("错误消息") → 1，与 CPython 语义一致
      }
      exception = null;
    }
  } finally {
    // 工作区收集：用户 code 抛异常也可能写过文件，成功失败都要收集
    const wsGlobals = pyodide.toPy({});
    try {
      await pyodide.runPythonAsync(WS_COLLECT_SRC, { globals: wsGlobals });
    } catch (e) {
      console.warn("[pyodide] 工作区收集失败:", e);
      window.__MS_WS_READY__ = false; // 收集失效即快照链路可疑，下轮强制重注入
    } finally {
      wsGlobals.destroy();
    }
    currentRunId = null;
  }
  const durationMs = Math.round(performance.now() - t0);
  post({
    kind: "runResult",
    id,
    stdout: stdoutBuf,
    stderr: "",
    exception,
    exitCode,
    durationMs,
    persistB64,
    wsWriteB64,
  });
  wsWriteB64 = null;
}

/// savefig 文件名保留（测试计划 I-2）：patch Figure.savefig，用户
/// savefig("qa.png") 的图经 Agg 渲染后以 __MS_SAVEFIG_PNG_B64__:<name>:
/// <b64> 打回 Swift，按用户文件名落盘（MEMFS 写入语义不变）。必须在
/// loadFromLockfile 之后调用——matplotlib 需先经用户代码的 import 加载，
/// bootstrap 时 import 会直接 ModuleNotFoundError；幂等（标志位防重）。
async function ensureSavefigPatched() {
  if (window.__MS_SAVEFIG_PATCHED__) return;
  try {
    await pyodide.runPythonAsync(
      "import os as _ms_os\n" +
      "import matplotlib.figure as _ms_mfig\n" +
      "_ms_orig_savefig = _ms_mfig.Figure.savefig\n" +
      "_ms_saved_figs = set()\n" +
      "def _ms_named_savefig(self, *a, **k):\n" +
      "    _f = a[0] if a else k.get('fname')\n" +
      "    if _f is None:\n" +
      "        import time as _ms_t\n" +
      "        _f = 'figure_%d.png' % int(_ms_t.time() * 1000)\n" +
      "        a = (_f,) + a\n" +
      "    if isinstance(_f, (str, _ms_os.PathLike)):\n" +
      "        try:\n" +
      "            import io as _io, base64 as _b64\n" +
      "            from matplotlib.backends.backend_agg import FigureCanvasAgg as _msAgg\n" +
      "            _c = _msAgg(self)\n" +
      "            _b = _io.BytesIO()\n" +
      "            _c.print_png(_b)\n" +
      "            _b.seek(0)\n" +
      "            _name = str(_f).replace('\\\\', '/').split('/')[-1]\n" +
      "            print('__MS_SAVEFIG_PNG_B64__:' + _name + ':' + _b64.b64encode(_b.read()).decode('ascii'))\n" +
      "            _ms_saved_figs.add(self.number)\n" +
      "        except Exception:\n" +
      "            pass\n" +
      "    return _ms_orig_savefig(self, *a, **k)\n" +
      "_ms_mfig.Figure.savefig = _ms_named_savefig"
    );
    window.__MS_SAVEFIG_PATCHED__ = true;
  } catch (e) {
    // matplotlib 未加载（用户没 import）时静默——没有 savefig 场景
  }
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
        _saved = globals().get('_ms_saved_figs', set())
        for _num in _nums:
            if _num in _saved:
                continue
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
    if (currentRunId !== null) {
      post({ kind: "stderr", id: currentRunId, line: "[terrarium] auto-show JS error: " + String(jsErr) });
    }
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
      // 注意：此 GUI 安装路径装进 purelib，不产出持久化镜像，重启后包丢失
      // （与终端 pip install 语义不一致；当前无调用方，保留待统一）
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
# /persist copy. We have to clean both so an uninstall actually frees the
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
    // 镜像重生成：/persist 已清除该包，按剩余内容重建 zip 回传 Swift 覆写，
    // 否则 Documents 里的旧镜像会让被卸载的包在重启后「复活」
    persistB64 = "";
    await pyodide.runPythonAsync(`
import io as _io, os as _os, zipfile as _zip, base64 as _b64
_buf = _io.BytesIO()
_n = 0
_z = _zip.ZipFile(_buf, 'w', _zip.ZIP_DEFLATED)
for _root, _dirs, _files in _os.walk('${PERSIST_DIR}/site-packages'):
    for _f in _files:
        _p = _os.path.join(_root, _f)
        _z.write(_p, _os.path.relpath(_p, '${PERSIST_DIR}'))
        _n += 1
_z.close()
if _n:
    print('__TERRARIUM_PERSIST_B64__:' + _b64.b64encode(_buf.getvalue()).decode())
`);
    post({ kind: "uninstallResult", id, pkg, ok: true, persistB64 });
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
    // /persist copy. Terminal-side pip installs land in /persist too.
    // So we have to scan BOTH locations to find every user-installed
    // package.
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

# Every site-packages dir Python knows about (Pyodide's + /persist copy).
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
    post({ kind: "clearResult", id, ok: true, persistB64: "" });
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
