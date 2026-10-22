# uu

自用远程桌面 homeuu（Mac ↔ Windows），基于 RustDesk：自建服务端，客户端在编译时改名并内置服务器配置。

- 技术方案：[docs/方案.md](docs/方案.md)
- **部署指南：[docs/部署指南.md](docs/部署指南.md)**

## 目录

| 路径 | 内容 |
|---|---|
| `server/install.sh` | 服务端一键部署（hbbs/hbbr + systemd） |
| `client/homeuu.json` | 产品名、端口、被控端锁定设置 |
| `client/customize.py` | 编译前改造 RustDesk 源码：改名、写入服务器、锁定设置 |
| `client/sign-macos.sh` | 在 Mac 上用自己的证书签名并安装 |
| `.github/workflows/build.yml` | 编译 Windows x64 MSI 和 macOS arm64 DMG |

本仓库不包含 RustDesk 源码。编译时拉取 `build.yml` 里 `RUSTDESK_COMMIT` 指定的版本再打补丁，升级 RustDesk 只需改这个提交号并重新编译；`customize.py` 找不到要改的原文时会报错，不会漏改。

RustDesk 采用 AGPL-3.0 许可证，homeuu 仅供自用。
