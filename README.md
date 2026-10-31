# electron-native-deps

Electron 37.2.2 的 Linux 原生依赖构建仓库，目标是让原生包使用不高于 GLIBC 2.28 的运行基线，覆盖 `x64`、`arm64` 和 Loong64，供 DSH HAREMESS + Electron 客户端使用。

仓库保存构建入口、固定版本、校验工具和真实存在的补丁。npm 上游源码、Electron、Docker 大镜像、sysroot、交叉编译器、Cargo 缓存和最终归档都作为构建输入或 GitHub Release 资产管理，不提交到 Git。

## 固定版本

版本与目标架构集中在 [`package.json`](package.json)：

| 依赖 | 版本 |
| --- | --- |
| Electron | 37.2.2 |
| node-pty | 1.1.0-beta33 |
| sharp | 0.32.6 |
| koffi | 3.3.3 |
| @deepseek-ai/node-addon-landlock-run | 0.1.1 |
| @vscode/ripgrep | 1.18.0 |
| sherpa-onnx-node | 1.13.8 |

构建脚本从这个清单生成归档文件名。升级版本时必须同时更新对应的锁定源码、平台包、工具链输入和验证记录。

## Docker 镜像和编译链

x64 和 arm64 使用 `electron37-native-builder:ubuntu18.04`。这是 GLIBC 2.27 的 Ubuntu 18.04 主机构建镜像，包含 Node.js、node-gyp、GCC、CMake、Meson、patchelf 和 arm64 交叉编译器。镜像由 [FusionSync/electron-loong64 的 toolchain-v1 Release](https://github.com/FusionSync/electron-loong64/releases/tag/toolchain-v1) 提供；也可以通过 `--host-image` 指定已有的等价镜像。脚本不会自动拉取或替换镜像。

Loong64 使用 `electron-loong64:gcc8-oldabi`。它以同一个 Ubuntu 18.04 主机构建镜像为基础，加入 UOS 20 GLIBC 2.28 sysroot、龙芯 GCC 8.3 旧 ABI 工具链、匹配的 libstdc++、CMake toolchain file 和 `uos-cc` 包装器。镜像及输入来自同一个 `toolchain-v1` Release。该容器只能生成 LoongArch64 ELF，不能在 x86_64 主机执行目标程序；归档必须在真实 Loong64/UOS 主机做 smoke test。

先准备工具链仓库并构建镜像：

```bash
git clone https://github.com/FusionSync/electron-loong64.git
cd electron-loong64
FETCH_INPUTS=1 FETCH_BASE_IMAGE=1 ./scripts/build-image.sh
```

这一步会校验 Release 中的 sysroot、GCC 和基础镜像，最终生成 `electron-loong64:gcc8-oldabi`。本仓库只消费已存在的镜像，不复制镜像层或工具链到 Git。

## x64/arm64 构建输入

`--build-root` 指向之前已经验证过的原生模块工作区。仓库中的 `scripts/host/` 是可执行的构建脚本，直接调用这些输入，不再依赖工作区里同名脚本：

```text
$NATIVE_BUILD_ROOT/
├── dependencies/package.json
├── dependencies/package-lock.json
├── dependencies/node_modules/       # 锁定的 node-pty、sharp、koffi 依赖树
├── docker/zig-cc-x64
├── docker/zig-cxx-x64
├── docker/zig-cc-arm64
├── docker/zig-cxx-arm64
└── research/
    ├── tools/meson-0.61.5/
    ├── vips-8.14.5/
    ├── cgif-0.3.2/
    ├── libimagequant-ce5fdeb1ccd9db288950faa21fd09c42c0a59bbb/
    ├── vips-sysroot-arm64/          # arm64 的 UOS/Ubuntu 目标库
    ├── runtime-debs*/
    └── vips-shared-licenses/
```

三个额外依赖放在独立的 `--extra-root`，避免把大源码和平台包放入仓库：

```text
$NATIVE_EXTRA_ROOT/
├── native-sources/
│   ├── landlock-run/src/main.c
│   ├── landlock-wrapper/             # @deepseek-ai/node-addon-landlock-run
│   ├── landlock-platform-x64/        # @deepseek-ai/node-addon-landlock-run-linux-x64
│   ├── landlock-platform-arm64/
│   ├── ripgrep/Cargo.toml
│   ├── ripgrep-wrapper/              # @vscode/ripgrep
│   ├── ripgrep-platform-x64/
│   ├── ripgrep-platform-arm64/
│   ├── sherpa-onnx/                  # sherpa-onnx 1.13.8 源码
│   └── sherpa-wrapper/               # sherpa-onnx-linux-${arch} 的 JS/package 元数据
├── onnxruntime/x64/lib/libonnxruntime.so*
├── onnxruntime/arm64/lib/libonnxruntime.so*
├── onnxruntime-headers/              # 与上面库匹配的 C/C++ headers
├── rust/bin/cargo
├── rust/bin/rustc
├── rust/bin/rustdoc
├── rust/cargo-config.toml
├── rust/cargo-home/                  # 已下载的 Cargo crates
└── sherpa-deps-cache/                # CMake FetchContent 的预取 _deps 内容
```

`build-host.sh` 的顺序是：构建 libimagequant/libvips，编译 node-pty、sharp、koffi，设置 sharp 的相对 RPATH，再编译 landlock-run、ripgrep 和 sherpa 的 Node-API addon，最后生成六个独立的 npm 模块归档。它不会执行 `npm install`，也不会联网下载另一套源码或运行库。`rust/cargo-home` 和 `sherpa-deps-cache` 必须是与源码版本匹配的完整缓存。

```bash
export NATIVE_BUILD_ROOT=/home/ubuntu/electron37-native-build
export NATIVE_EXTRA_ROOT=/home/ubuntu/electron37-native-extra

scripts/build.sh --arch x64 --build-root "$NATIVE_BUILD_ROOT" \
  --extra-root "$NATIVE_EXTRA_ROOT" --output /tmp/electron-native-release
scripts/build.sh --arch arm64 --build-root "$NATIVE_BUILD_ROOT" \
  --extra-root "$NATIVE_EXTRA_ROOT" --output /tmp/electron-native-release
```

如果之前已经准备好 `electron37-native-builder:glibc2.27`，可以显式传入：

```bash
scripts/build.sh --arch x64 --host-image electron37-native-builder:glibc2.27 \
  --build-root "$NATIVE_BUILD_ROOT" --extra-root "$NATIVE_EXTRA_ROOT"
```

## Loong64 构建输入和流程

Loong64 的所有宿主路径必须位于 `--loong-root` 下，因为脚本会把该目录挂载到容器 `/work`。目录至少需要：

```text
$LOONG_TOOLCHAIN_ROOT/
├── native-sources/
│   ├── node-pty/
│   ├── sharp/
│   ├── sharp-vendor/                 # libvips 8.14.5 的 Loong64 vendor tree
│   ├── koffi/
│   ├── koffi-platform/
│   ├── landlock-run/
│   ├── node-addon-landlock-run/
│   ├── node-addon-landlock-run-platform-loong64/
│   ├── ripgrep/
│   ├── ripgrep-wrapper/
│   ├── ripgrep-platform-loong64/
│   ├── sherpa-onnx/
│   └── sherpa-wrapper/
├── onnxruntime-loong64/lib/libonnxruntime.so*
├── onnxruntime-headers/
├── electron37-attempt/tools/rust188/bin/rustc
├── electron37-attempt/tools/rust188/bin/rustdoc
├── electron37-attempt/src/third_party/rust-toolchain/bin/cargo
├── cargo-config/config.toml
├── cargo-home/                       # Rust 1.88 的 crates 缓存
└── sherpa-deps-cache/                # 预取的 CMake _deps
```

执行流程与宿主架构一致：UOS GCC 编译 node-pty、sharp、koffi 和静态 landlock-run；Rust/Cargo 交叉编译 ripgrep；先构建 sherpa C/C++ 库，再用 `/opt/node` headers 构建 Node-API addon。ONNX Runtime 头文件和动态库通过显式目录传给 CMake，所有 addon/共享库写入 `$ORIGIN` RPATH，sharp addon 指向自身 vendor 目录。

```bash
export LOONG_TOOLCHAIN_ROOT=/home/ubuntu/uos-loongarch64-cross
scripts/build.sh --arch loong64 --loong-root "$LOONG_TOOLCHAIN_ROOT" \
  --output /tmp/electron-native-release
```

默认镜像可用 `--loong-image` 或 `LOONG_IMAGE` 覆盖。构建网络默认关闭；如果 CMake 缓存、Cargo crates 或 ONNX Runtime 输入缺失，脚本会在编译前失败，不会生成不完整归档。

## 校验和发布

```bash
python3 scripts/verify-release.py /tmp/electron-native-release \
  --json /tmp/electron-native-release/verification.json
python3 scripts/generate-manifest.py /tmp/electron-native-release
(cd /tmp/electron-native-release && sha256sum *.tar.gz > SHA256SUMS)
```

`verify-release.py` 检查归档内必需文件、ELF 架构、最高 GLIBC 符号版本和动态库 RPATH。校验通过后仍要在 x64、arm64、Loong64 目标机做实际 Electron smoke test，再上传 GitHub Release。归档名称不带业务项目前缀，例如：

```text
node-pty-1.1.0-beta33-linux-loong64.tar.gz
sharp-0.32.6-linux-arm64.tar.gz
koffi-3.3.3-linux-x64.tar.gz
landlock-run-0.1.1-linux-loong64.tar.gz
ripgrep-1.18.0-linux-arm64.tar.gz
sherpa-onnx-node-1.13.8-linux-loong64.tar.gz
```

## Patch 维护

补丁按“上游组件/版本”存放。当前仓库记录两类实际使用的补丁：

| 组件 | 版本 | 用途 |
| --- | --- | --- |
| ONNX Runtime | 1.28.0 | cpuinfo LoongArch 支持，以及 Loong64 构建脚本修正 |
| `builder-util` | 25.1.7 | 注册 `loong64`、`riscv64`、`mips64el` 架构及 Linux 映射 |
| `app-builder-lib` | 25.1.8 | 允许打包配置声明这些架构 |
| `electron-builder` | 25.1.8 | 增加 `--loong64` 和 `--mips64el` 命令行选项 |
| `app-builder-bin` | 5.0.0-alpha.10 | 在 Loong64 主机上兼容 `loong64`/`loongarch64` 二进制目录 |
| `app-builder` | 5.0.0-alpha.13 | 支持 `mips64el` AppImage，并允许从环境变量指定 AppImage 工具包 |

electron-builder 相关补丁只负责打包工具识别目标架构；它们不会编译 Electron 或原生依赖。`app-builder` 是 Linux x64 主机构建工具，AppImage 仍需另外提供对应的 `runtime-loong64` 或 `runtime-mips64el`。Electron 本体的 Loong64/Chromium 补丁继续由 [FusionSync/electron-loong64](https://github.com/FusionSync/electron-loong64) 维护，本仓库不重复复制。

ONNX Runtime 补丁位于：

```text
patches/onnxruntime/1.28.0/0001-cpuinfo-loong64.patch
patches/onnxruntime/1.28.0/0002-onnxruntime-build.patch
```

第一份补丁为 cpuinfo 的 LoongArch 支持，第二份补丁修改 ONNX Runtime 的构建脚本和 cpuinfo portfile。应用时把第一份补丁保存为 ONNX Runtime 源码 `cmake/vcpkg-ports/cpuinfo/patch_cpuinfo_h_for_loong64.patch`，再应用第二份补丁；这样 vcpkg 才会在构建 cpuinfo 时使用 LoongArch 代码。构建输入应先按 ONNX Runtime 1.28.0 的源码流程应用补丁并生成 `onnxruntime/*/lib` 与匹配 headers，再把生成结果放入输入目录；本仓库的依赖构建脚本只消费这些已构建输入，不会偷偷使用其它架构的预编译库。

electron-builder 的 `patch-package` 补丁按以下顺序应用：

```text
builder-util
app-builder-lib
electron-builder
app-builder-bin
```

`app-builder` 源码补丁在构建自定义 app-builder 时使用 `git apply`。补丁原文件来自前端仓库的 `patches/` 和 `src/client/builder/electron-make/app-builder/`，这里按组件版本归档，便于打包工具链和原生依赖使用同一份版本记录。升级任一上游版本时建立新的版本目录，并在对应源码上使用 `git apply --check` 验证；没有真实源码补丁的依赖不创建空目录。

## 兼容性边界

这里发布的是原生依赖，满足 GLIBC 2.28 的符号上限不代表 Electron 本体、系统图形库、内核能力和目标发行版 ABI 自动兼容。尤其 Loong64 必须使用能在目标系统启动的 Electron 构建；降低 `.node` 或共享库的 GLIBC 要求不能修复 Electron 本体的 ABI 要求。
