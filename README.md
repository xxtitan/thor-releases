# thor

雷神网络加速服务的命令行客户端，内置管理中心网页，支持本地 SOCKS5（TCP 与 UDP）、按目标分流与按流量自动管理账号计时。

本仓库发布 thor 的安装脚本与各平台可执行文件。

## 安装

macOS / Linux：

```bash
curl -fsSL https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.sh | sh
```

Windows（PowerShell）：

```powershell
irm https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.ps1 | iex
```

无法访问 GitHub 时，在脚本地址前加上 `https://gh-proxy.com/`；脚本下载 thor 时也会自动改经该代理。

### 安装为自启服务

自启服务在开机（macOS 为登录）后运行 `thor web serve`，管理中心地址默认 `http://127.0.0.1:7998`：

```bash
curl -fsSL https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.sh | sh -s -- --service
```

```powershell
# 在“以管理员身份运行”的 PowerShell 中执行
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.ps1))) -Service
```

| `install.sh` | `install.ps1` | 作用 |
| --- | --- | --- |
| `--service` | `-Service` | 安装为自启服务 |
| `--listen <地址>` | `-Listen` | 自启服务的管理中心地址，默认 `127.0.0.1:7998` |
| `--channel <stable\|nightly>` | `-Channel` | 发布通道，默认 `stable` |
| `--dir <目录>` | `-Dir` | 安装目录，默认 `~/.local/bin`；Windows 为 `%LOCALAPPDATA%\Programs\thor` |
| `--uninstall` | `-Uninstall` | 卸载 thor 与自启服务，保留数据 |

重复执行安装命令即升级到最新版本。

## 更新

```bash
thor update                    # 检查并安装新版本
thor update --check            # 只检查
thor update --channel nightly  # 切换到 nightly 通道
```

发布版分为 `stable`（正式版本）与 `nightly`（每日构建）两个通道。管理中心每天自动检查一次更新，更新在重启 thor 后生效。

## 手动下载

在 [Releases](https://github.com/xxtitan/thor-releases/releases) 下载对应平台的 `thor-<os>-<arch>[.exe]`，用 `checksums.txt` 校验后放入 `PATH`。支持 `linux-amd64`、`linux-arm64`、`linux-arm`、`darwin-amd64`、`darwin-arm64`、`windows-amd64`、`windows-arm64`。
