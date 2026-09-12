#!/usr/bin/env bash
#
# fetch-pyodide.sh — 下载离线 Pyodide 运行时并生成路由包名表
#
# 产物（全部提交进 git，App 完全离线可用）：
#   Sources/Terrarium/Resources/pyodide-runtime/   core 运行时 + 依赖闭包 wheels
#   pyodide_imports.json                           import 名 → 发行名 反向索引（宿主路由查表）
#
# 用法：./Scripts/fetch-pyodide.sh    （幂等，可重复执行）
#
set -euo pipefail

PYODIDE_VERSION="0.29.4"
# 注意：GitHub release tag 无 v 前缀；jsDelivr 路径带 v 前缀
CORE_URL="https://github.com/pyodide/pyodide/releases/download/${PYODIDE_VERSION}/pyodide-core-${PYODIDE_VERSION}.tar.bz2"
CDN="https://cdn.jsdelivr.net/pyodide/v${PYODIDE_VERSION}/full"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${REPO_ROOT}/Sources/Terrarium/Resources/pyodide-runtime"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"

# ── 1. core 运行时（排除 python.exe 与 *.d.ts，App 内用不到） ──
if [ -f "$DEST/pyodide-lock.json" ]; then
    echo "==> core 已存在，跳过下载"
else
    echo "==> 下载 pyodide-core ${PYODIDE_VERSION} ..."
    curl -fL --retry 3 -o "${TMP}/core.tar.bz2" "$CORE_URL"
    tar xjf "${TMP}/core.tar.bz2" -C "$TMP"
    for f in pyodide.asm.wasm pyodide.asm.js pyodide.js pyodide.mjs python_stdlib.zip pyodide-lock.json; do
        cp "${TMP}/pyodide/$f" "$DEST/"
    done
fi

# ── 2. 依赖闭包 wheels（sha256 按 lockfile 校验）+ 3. 路由包名表 ──
python3 - "$DEST" "$CDN" "$REPO_ROOT" "$PYODIDE_VERSION" <<'PYEOF'
import hashlib, json, os, subprocess, sys

dest, cdn, repo_root, version = sys.argv[1:5]
lock = json.load(open(os.path.join(dest, "pyodide-lock.json")))
pkgs = lock["packages"] if isinstance(lock["packages"], dict) else {p["name"]: p for p in lock["packages"]}

# numpy + pandas + matplotlib 的传递依赖闭包
# micropip：bootstrap 阶段 loadPackage("micropip") 必需，缺了会 404 导致启动失败
# tushare 依赖树：requests/bs4/lxml 等全在锁表内，打包后 micropip 兜底
# 只需从 PyPI 拉 tushare 本体（纯 wheel），依赖走本地离线伺服
targets = ["numpy", "pandas", "matplotlib", "micropip",
           "requests", "beautifulsoup4", "lxml", "tqdm",
           "typing-extensions", "simplejson", "ssl"]
need = set()
def add(name):
    if name in need or name not in pkgs:
        return
    need.add(name)
    for dep in pkgs[name].get("depends", []):
        add(dep)
for t in targets:
    add(t)
print(f"==> 依赖闭包 {len(need)} 个包")

for name in sorted(need):
    pkg = pkgs[name]
    fn = pkg["file_name"]
    path = os.path.join(dest, fn)
    want = pkg.get("sha256", "")

    def sha256_ok():
        if not want or not os.path.exists(path):
            return False
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest() == want

    if sha256_ok():
        print(f"  已存在并校验通过  {fn}")
        continue
    print(f"  下载              {fn}")
    subprocess.run(["curl", "-fL", "--retry", "3", "-o", path, f"{cdn}/{fn}"], check=True)
    if not sha256_ok():
        print(f"  sha256 校验失败：{fn}")
        sys.exit(1)

# import 名反向索引：lockfile 的 name 是发行名（scikit-learn），imports 才是 import 名（sklearn）
table = {}
for name, pkg in pkgs.items():
    for imp in pkg.get("imports", []):
        table[imp] = name
out_path = os.path.join(repo_root, "pyodide_imports.json")
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(
        {"pyodide_version": version, "imports": table},
        f, ensure_ascii=False, indent=1, sort_keys=True,
    )
print(f"==> pyodide_imports.json 生成（{len(table)} 个 import 名）")
PYEOF

echo "==> 完成：$DEST $(du -sh "$DEST" | cut -f1) / $(ls "$DEST" | wc -l | tr -d ' ') 个文件"
