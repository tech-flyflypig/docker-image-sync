# Docker Images Pusher

使用 GitHub Action 把国外的 Docker 镜像转存到阿里云容器镜像服务（ACR），国内服务器直接从阿里云拉取，免费、无需自己维护机器。

- 支持 Docker Hub、gcr.io、ghcr.io、quay.io、k8s.io 等任意仓库
- 支持最大 40GB 的大镜像（构建前自动扩容并逐个清理，不会撑爆 runner）
- 一次运行可推送到**多个阿里云命名空间**，命名空间在 `images.txt` 里按段落/按行指定
- 使用阿里云官方线路，国内拉取速度快

```
上游镜像仓库  →  GitHub Action Runner（pull / tag）  →  阿里云 ACR  →  国内服务器 pull
```

## 使用方式

### 1. 准备阿里云仓库

登录阿里云容器镜像服务：https://cr.console.aliyun.com/

启用个人实例，创建一个命名空间（这个值稍后要写进 `images.txt`，例如 `[huayangtongxin]`）。

![](doc/命名空间.png)

然后到「访问凭证」页获取三个值：

| 名称 | 说明 |
| --- | --- |
| `ALIYUN_REGISTRY` | 仓库地址，如 `registry.cn-hangzhou.aliyuncs.com` |
| `ALIYUN_REGISTRY_USER` | 用户名 |
| `ALIYUN_REGISTRY_PASSWORD` | 密码（固定密码或临时密码） |

![](doc/用户名密码.png)

### 2. 部署到你自己的仓库

把本项目推送到你自己的 GitHub 仓库（Fork / Use this template / 直接 push 均可）。

#### 启用 Action

进入仓库的 Actions 页面，点击启用 GitHub Actions。

#### 配置 Secrets

进入 Settings → Secrets and variables → Actions → New repository secret，把上一步的三个值配好：

```
ALIYUN_REGISTRY
ALIYUN_REGISTRY_USER
ALIYUN_REGISTRY_PASSWORD
```

命名空间**不放**在 Secret 里，而是写在 `images.txt` 中（见下节），这样一个仓库就能同时推多个命名空间。

![](doc/配置环境变量.png)

### 3. 添加镜像

编辑仓库根目录的 `images.txt`，每行一个镜像：

| 写法 | 说明 |
| --- | --- |
| `nginx:1.28.3-alpine` | 镜像名 + tag，不写 tag 默认 `latest` |
| `[huayangtongxin]` | 段落头，之后的所有镜像都推到该命名空间 |
| `--space=infra nginx` | 单行指定命名空间，优先级高于段落 |
| `--platform=linux/arm64 nginx` | 指定架构，架构会作为前缀出现在镜像名前 |
| `k8s.gcr.io/kube-state-metrics/kube-state-metrics` | 从私有仓库拉取 |
| `# 注释` | `#` 开头整行忽略 |

`images.txt` 里必须有命名空间段落或 `--space=`，否则运行时会先做预检查并直接报错，不会推到一半才失败。

![](doc/images.png)

文件提交（push 到 `main`）后自动进入 GitHub Action 构建。只有 `images.txt` 或 `.github/workflows/docker.yaml` 变更才会触发，改文档不会触发搬运。

单个镜像失败不会中断整批：剩余镜像会继续搬运，最后 job 标记失败并打印失败清单，修好后重跑即可（已成功的镜像会再推一次，tag 相同，无副作用）。

### 4. 使用镜像

回到阿里云镜像仓库，点击任意镜像可以查看状态（也可以把仓库改成公开，拉取时免登录）。

![](doc/开始使用.png)

在国内服务器上拉取，例如：

```bash
docker pull registry.cn-hangzhou.aliyuncs.com/huayangtongxin/alpine
```

- `registry.cn-hangzhou.aliyuncs.com` 即 `ALIYUN_REGISTRY`
- `huayangtongxin` 即 `images.txt` 里 `[]` 中填写的命名空间
- `alpine` 即阿里云仓库中显示的镜像名

### 5. 多命名空间

没有全局默认命名空间，**每个镜像都要写明目标命名空间**。优先级：

```
--space=xxx（单行） > [xxx]（段落）
```

段落式，适合成组推送：

```ini
[huayangtongxin]
nginx:1.28.3-alpine
redis:7.4.9-alpine

[infra]
golang:1.22-alpine
```

单行式，适合个别镜像：

```ini
--space=infra --platform=linux/amd64 livekit/livekit-server:v1.13.1
```

注意：

- 缺命名空间、命名空间非法（只允许小写字母、数字、短划线）都会在**预检查阶段**报错中止，一个镜像都不会 pull
- 所有命名空间必须在同一个仓库地址、同一套账号密码下（workflow 只登录一次）
- 阿里云个人实例的命名空间数量有配额限制，需要多个命名空间请确认实例类型（企业版支持多命名空间）

### 6. 多架构

需要在 `images.txt` 中用 `--platform=xxxxx` 手动指定架构，指定后的架构会以前缀的形式放在镜像名前面：

```ini
--platform=linux/amd64 nginx:1.28.3-alpine
```

推送结果是 `linux_amd64_nginx:1.28.3-alpine`。注意这是把**该架构的单个镜像**另存一份，不是多架构 manifest（不会自动选架构）。

![](doc/多架构.png)

### 7. 镜像重名

程序会自动判断同一个目标命名空间内是否存在「镜像名相同、但上游命名空间不同」的情况，如果存在，把上游命名空间作为前缀加在镜像名前。例如：

```ini
[huayangtongxin]
xhofe/alist
xiaoyaliu/alist
```

推送结果为 `xhofe_alist`、`xiaoyaliu_alist`，不会互相覆盖。

![](doc/镜像重名.png)

### 8. 定时执行

在 `.github/workflows/docker.yaml` 的 `on:` 下加 `schedule` 即可（cron 使用 UTC 时区）：

```yaml
on:
  workflow_dispatch:
  push:
    branches: [ main ]
  schedule:
    - cron: '0 18 * * *'   # 每天 UTC 18:00，即北京时间 02:00
```

![](doc/定时执行.png)

## 常见问题

- **拉取失败 `invalid reference format`**：多半是 `images.txt` 里多了不可见字符或全角空格，删掉重输即可
- **推送 403 / denied**：检查 Secrets 是否为该命名空间所属账号的凭证，以及 `ALIYUN_REGISTRY` 是否与命名空间对应
- **磁盘不足**：镜像超过 40GB 时可以在 `maximize-build-space` 步骤里打开 `remove-android`、`remove-codeql`，或拆成多次运行
