# Linux 运维工具集

常用 Linux 自动化运维配置与初始化脚本。

## 目录与功能

### 1. SSH 密钥与认证管理 (`ssh/`)

自动检测当前 SSH 登录模式（纯密码 / 密码+密钥混合 / 纯密钥），校验公钥一致性，支持一键配置目标公钥并安全关闭密码登录。

- **快速一键执行命令**：
  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/setup_ssh.sh)
  ```
- **公钥文件**：[`ssh/target_key.pub`](ssh/target_key.pub)（后续如需更换公钥直接修改此文件推送到 GitHub 即可）。

---

### 2. 系统初始化脚本 (`init.sh`)

Debian 系统自动化一键配置（WARP、BBR、ZRAM、Swap、Docker、时区校准与基础工具）。

- **一键执行命令**：
  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/fox-baixi/linux/main/init.sh)
  ```

---

### 3. 备份安装器 (`backup-installer/`)

交互式系统与数据备份管理，详见 [backup-installer/README.md](backup-installer/README.md)。

- **一键执行命令**：
  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/fox-baixi/linux/main/backup-installer/install.sh)
  ```