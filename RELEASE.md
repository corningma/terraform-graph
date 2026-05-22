# Release Guide

本项目使用 [GitHub Actions](.github/workflows/release.yml) 自动构建多平台二进制并发布到 Releases。

## 触发自动发布

### 方式 A：推送 Git tag（推荐）

```bash
git checkout master
git pull
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

GitHub Actions 会自动：

1. 在 `ubuntu-latest` / `macos-13` / `macos-14` / `windows-latest` 四台 runner 上并行构建
2. 用 PyInstaller 把 `server` 和 `agent` 打成单文件二进制
3. 计算 SHA256 校验和
4. 创建对应 tag 的 Release

### 方式 B：手动触发

GitHub 网页 → Actions → Release → Run workflow，可选填 tag 名。

## 命名约定

| Tag | 类型 |
|---|---|
| `v1.0.0` | 正式版 |
| `v1.0.0-rc.1`, `v1.0.0-beta` | 预发布 |

## 本地手动构建

```bash
pip install -r requirements-build.txt -r server/requirements.txt -r agent/requirements.txt

pyinstaller server/build.spec --clean --noconfirm
# → dist/tfgraph-server[.exe]

pyinstaller agent/build.spec --clean --noconfirm
# → dist/tfgraph-agent[.exe]
```

## 二进制运行

- **tfgraph-server**：默认监听 `0.0.0.0:8000`，通过环境变量 `TFGRAPH_HOST` / `TFGRAPH_PORT` 覆盖。
  数据库 `data.db` 写入当前工作目录。
- **tfgraph-agent**：与源码版本完全等价。`TFGRAPH_SERVER` 指定 Server 地址。

## 二进制大小

| 组件 | 大小（约） |
|---|---|
| tfgraph-server | ~25-35 MB |
| tfgraph-agent  | ~10-15 MB |
