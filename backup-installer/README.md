# backup-installer

交互式备份安装器。

## 一键运行

```bash
bash <(curl -sSL https://raw.githubusercontent.com/fox-baixi/linux/main/backup-installer/install.sh)
```

## 功能

- 安装备份脚本
- 执行一次备份
- 升级脚本
- 卸载脚本 / 配置 / 定时任务
- 查看和修改配置
- 管理 cron 定时任务
- 查看日志

## 目录结构

安装后默认使用：

- `/root/back/backup.sh`
- `/root/back/backup.env`
- `/root/back/backup.env.example`

## 依赖

- bash
- curl
- tar
- rclone

安装器会在安装、升级、执行一次备份前检查运行依赖。
