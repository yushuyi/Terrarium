# Terrarium（fork：离线 Pyodide 桥）

> fork 自 [haplollc/Terrarium](https://github.com/haplollc/Terrarium)（MIT）。
> 本 fork 做了减法手术：**只保留「Pyodide 桥」**，作为 MianShu 的离线科学计算 Python 通道。

## 这个包现在是什么

- 隐藏 WKWebView 中运行 [Pyodide](https://pyodide.org)（CPython 3.13 编译到 WebAssembly）
- `PyodideBridge`：Swift async API（`runPython` / `installPackage` / `listPackages` / `uninstallPackage` / `clearAllPackages`）
- `Resources/pyodide-runtime/`：离线 bundle（pyodide-core + numpy/pandas/matplotlib 依赖闭包，约 28MB）——由 `Scripts/fetch-pyodide.sh` 生成
- `PyodideSchemeHandler`：WKURLSchemeHandler 本地伺服，绕开 WKWebView 对 `file://` 的 fetch 限制

## 这个包不再是什么

上游的以下能力已全部剥离，由宿主 App（MianShu）自身承担：

- 内嵌 CPython 3.13 运行时（`Python.xcframework` + python-stdlib + lib-dynload + site-packages，约 74MB）
- `%pip` magic、包管理器、脚本管理器、SwiftUI 运行界面

宿主 MianShu 已内嵌 BeeWare CPython 3.14.2：纯 Python 走原生通道，C 扩展包按 import 扫描路由到本桥。设计与实施方案见主仓 `MianshuAgent/docs/Terrarium-Pyodide离线运行时-*.md`。

## 使用

```swift
import Terrarium

let result = await PyodideBridge.shared.runPython(code: "print('hello')")
print(result.stdout)
```

## License

MIT——原始版权归 Haplo, LLC（见 `LICENSE`）。
