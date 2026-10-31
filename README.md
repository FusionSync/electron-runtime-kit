# electron-runtime-kit

面向国内 Electron 开发者的 Linux 运行时构建、打包和发布经验库。

本项目把一套容易反复踩坑的流程固定下来：在 **x86_64 构建机**上使用可复现的 Docker 编译环境，生成 Electron 所需的原生 Node 模块、架构相关工具和运行库，完成 ELF/GLIBC 校验后上传到 GitHub Release。目标平台覆盖 Linux `x64`、`arm64` 和 LoongArch64，运行基线为 **GLIBC 2.28 或更低**。

项目重点是节省源码调研、交叉编译、低版本 GLIBC 兼容和打包工具适配的时间。仓库提交脚本、固定版本、补丁、校验逻辑和构建记录；大体积源码、编译器、sysroot、Docker 镜像和最终二进制放在外部输入或 GitHub Release 中。

## 当前版本和 Release

当前验证矩阵为：

| 项目 | 值 |
| --- | --- |
| Electron | 37.2.2 |
| 构建主机 | x86_64 Linux |
| 目标平台 | Linux x64、arm64、LoongArch64 |
| GLIBC 上限 | 2.28 |
| node-pty | 1.1.0-beta33 |
| sharp | 0.32.6 |
| koffi | 3.3.3 |
| landlock-run | 0.1.1 |
| ripgrep | 1.18.0 |
| sherpa-onnx-node | 1.13.8 |

Release 按 Electron、GLIBC 和目标架构命名，例如 `electron-v37.2.2-glibc-2.28`。每个 Release 包含：

- 六类原生 npm 运行包，每类提供 x64、arm64、Loong64 三个归档；
- `manifest.json`，记录 Electron 版本、构建主机、架构、工具链和每个归档的 SHA-256；
- `SHA256SUMS`，用于下载后校验；
- Release notes，说明源码版本、Docker 镜像、补丁和已完成的目标机验证。

Electron 主程序本身由 [FusionSync/electron-loong64](https://github.com/FusionSync/electron-loong64) 或对应的 Electron 发布源提供。本仓库负责它运行时依赖的构建、布局和发布；将 Electron 压缩包与这里的原生包组合后，才是完整的 Electron Linux 运行时交付物。没有列在 Release 资产中的文件不应被默认为已构建或已验证。

## 构建链路

所有目标都从 x86_64 主机启动 Docker。构建过程分为四步：

1. 准备锁定版本的 npm 源码、Node headers、libvips、ONNX Runtime、Rust/Cargo 缓存和目标平台工具链；
2. 在 `electron37-native-builder:ubuntu18.04` 中构建 x64/arm64 依赖，在 `electron-loong64:gcc8-oldabi` 中用 UOS GLIBC 2.28 sysroot 和 GCC 8.3 交叉构建 Loong64；
3. 将 `.node`、共享库和命令行工具整理成 npm 原有目录布局，写入相对 `$ORIGIN` RPATH；
4. 使用 `verify-release.py` 检查 ELF 架构、最高 GLIBC 符号、归档目录和 RPATH，再生成 manifest、SHA256SUMS 并上传 Release。

### Docker 镜像

两个镜像由 [FusionSync/electron-loong64 的 `toolchain-v1` Release](https://github.com/FusionSync/electron-loong64/releases/tag/toolchain-v1) 提供输入：

- `electron37-native-builder:ubuntu18.04`：GLIBC 2.27 的 x86_64 构建环境，包含 Node.js、node-gyp、GCC、CMake、Meson、patchelf 和 arm64 交叉工具；
- `electron-loong64:gcc8-oldabi`：以上镜像加入 UOS 20 GLIBC 2.28 sysroot、龙芯 GCC 8.3、旧 ABI `libstdc++` 和 CMake toolchain 后生成的 Loong64 交叉编译环境。

```bash
git clone https://github.com/FusionSync/electron-loong64.git
cd electron-loong64
FETCH_INPUTS=1 FETCH_BASE_IMAGE=1 ./scripts/build-image.sh
```

`electron-runtime-kit` 不自动下载或替换镜像，只检查指定标签是否存在。Loong64 镜像只能生成目标 ELF，不能在 x86_64 主机运行；发布前仍需在真实 Loong64 系统做启动和 Electron smoke test。

### 构建原生包

先准备两个外部工作区。它们包含大体积源码和缓存，不应复制到本仓库：

```text
NATIVE_BUILD_ROOT/       # x64/arm64 源码、锁文件、libvips 和交叉工具
NATIVE_EXTRA_ROOT/       # landlock、ripgrep、sherpa、ONNX Runtime、Rust/Cargo 缓存
LOONG_TOOLCHAIN_ROOT/    # Loong64 源码、sysroot 输入、Rust 和 CMake 缓存
```

在 x86_64 主机执行：

```bash
export NATIVE_BUILD_ROOT=/home/ubuntu/electron37-native-build
export NATIVE_EXTRA_ROOT=/home/ubuntu/electron37-native-extra
export LOONG_TOOLCHAIN_ROOT=/home/ubuntu/uos-loongarch64-cross

# 构建一个架构
scripts/build.sh --arch x64 --build-root "$NATIVE_BUILD_ROOT" \
  --extra-root "$NATIVE_EXTRA_ROOT" --output ./dist

# 构建全部目标
scripts/build.sh --arch all --build-root "$NATIVE_BUILD_ROOT" \
  --extra-root "$NATIVE_EXTRA_ROOT" --loong-root "$LOONG_TOOLCHAIN_ROOT" \
  --output ./dist
```

脚本不会执行 `npm install`，也不会联网下载另一套源码。缺少锁定输入、Cargo 缓存、CMake 依赖或 ONNX Runtime 时会在编译前失败。

六类归档的布局与插件加载器保持一致：

```text
node-pty-1.1.0-beta33-linux-loong64.tar.gz
sharp-0.32.6-linux-arm64.tar.gz
koffi-3.3.3-linux-x64.tar.gz
landlock-run-0.1.1-linux-loong64.tar.gz
ripgrep-1.18.0-linux-arm64.tar.gz
sherpa-onnx-node-1.13.8-linux-loong64.tar.gz
```

解压归档时使用归档根目录覆盖目标插件的 `node_modules`，不要只替换单个 `.node` 文件。`sharp` 同时包含 libvips 和配套动态库，`sherpa-onnx-node` 同时包含 Node-API addon、sherpa 库和 ONNX Runtime。

## 校验和发布

构建完成后先在构建机运行：

```bash
python3 scripts/verify-release.py ./dist --json ./dist/verification.json
python3 scripts/generate-manifest.py ./dist
(cd ./dist && sha256sum *.tar.gz > SHA256SUMS)
```

校验通过后，把 `*.tar.gz`、`manifest.json` 和 `SHA256SUMS` 上传到对应 GitHub Release。Release 资产不提交到 Git；版本、构建主机、目标架构、Docker 标签、工具链 Release、源码 commit 和验证结果写入 Release notes 或 manifest。

`verify-release.py` 会检查：

- 归档内必需文件和 npm 目录布局；
- ELF 架构是否与归档目标一致；
- 最高 GLIBC 符号版本是否不超过 2.28；
- sharp、sherpa Node-API addon 是否使用相对 RPATH；
- 归档名称、版本和目标架构是否符合 manifest 规则。

Release 资产通过后仍要在 x64、arm64、Loong64 目标机运行实际 Electron smoke test。GLIBC 兼容只说明原生依赖的符号上限，不能替代 Electron 主程序、图形库、内核能力和发行版 ABI 的验证。

## Electron 打包工具

Electron 打包工具需要认识国产架构，相关补丁按组件和版本存放在 `patches/`：

| 组件 | 版本 | 用途 |
| --- | --- | --- |
| `builder-util` | 25.1.7 | 注册 Loong64、RISC-V64、MIPS64el 架构及 Linux 映射 |
| `app-builder-lib` | 25.1.8 | 允许打包配置声明这些架构 |
| `electron-builder` | 25.1.8 | 增加 `--loong64` 和 `--mips64el` 命令行选项 |
| `app-builder-bin` | 5.0.0-alpha.10 | 兼容 Loong64/LoongArch64 的 app-builder 二进制目录 |
| `app-builder` | 5.0.0-alpha.13 | 支持 MIPS64el AppImage，并允许指定 AppImage 工具包地址和校验值 |
| ONNX Runtime | 1.28.0 | 为 sherpa 构建提供 LoongArch64 cpuinfo 和构建修正 |

前四类是 npm `patch-package` 补丁，应用顺序为 `builder-util`、`app-builder-lib`、`electron-builder`、`app-builder-bin`；`app-builder` 源码补丁在构建自定义 Go 工具时使用 `git apply`。Electron/Chromium 本体补丁仍由 `electron-loong64` 维护，本项目不重复复制。

## 项目边界

- 本项目记录可复用的构建经验和发布产物，不是 npm 源码镜像；
- 原生模块的源码和平台包是构建输入，产物以 GitHub Release 归档；
- 当前 `scripts/build.sh` 生成的是 Electron 原生运行依赖包，Electron 核心二进制仍来自对应的 Electron 发布源；
- `x64`、`arm64` 和 `loong64` 的产物必须分别验证，不能因为一个架构通过就推断其他架构可用；
- 没有真实源码补丁的依赖不创建空 patch 目录，版本升级时必须在对应源码上执行 `git apply --check`。

欢迎国内 Electron 项目复用版本清单、Docker 方案、补丁和验证脚本，并在 Release notes 中补充目标系统和实际验证结果。
