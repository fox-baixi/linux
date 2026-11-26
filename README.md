# 自用工具

# Linux 运维工具集

常用 Linux 自动化运维配置与初始化脚本。

## 目录与功能

### 1. SSH 密钥与认证管理 (`ssh/`)

- **公钥文件**：[`ssh/target_key.pub`](ssh/target_key.pub)（后续如需更换公钥直接修改此文件推送到 GitHub 即可）。

#### 方式 A：免确认极速全自动执行（推荐：0 交互直接执行）
自动比对公钥与密码状态，若未配置或公钥不符则自动写入并关闭密码登录，自动重启生效：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/auto_ssh.sh)
```

#### 方式 B：单次确认交互执行
自动检测状态，仅需确认一次即可完成更新并自动关闭密码登录：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/setup_ssh.sh)
```

#### 方式 C：dsh 专属受限公钥管理（限制来源 IP，安全增量追加/更新）
- **专属公钥文件**：[`ssh/dsh_key.pub`](ssh/dsh_key.pub)
- **特性**：不覆盖、不冲突原有公钥；自动比对 `dsh` 标识公钥及 IP 限制规则，已是最新则跳过，旧版本则自动更新。
- **IP 限制（动态）**：白名单不再写死某个 IPv4 网段（家宽换段即失效），执行时按当前 SSH 会话的客户端地址自动生成——IPv4 归并为 `/24`，IPv6 归并为 `/48`；同一协议族用新地址替换旧记录，另一协议族保留原值（从 IPv4 执行不会冲掉 IPv6，反之亦然）；检测不到会话地址时回退默认值。需要强制指定时用环境变量：`DSH_ALLOW_CIDRS="1.2.3.0/24,2409:xxxx:xxxx::/48" bash dsh_ssh.sh`
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/dsh_ssh.sh)
```


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
