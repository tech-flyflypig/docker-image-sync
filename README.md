# Docker Image Sync

使用 GitHub Action 把国外的 Docker 镜像转存到阿里云容器镜像服务（ACR），国内服务器直接从阿里云拉取，免费、无需自己维护机器。

- 支持 Docker Hub、gcr.io、ghcr.io、quay.io、k8s.io 等任意仓库
- 用 skopeo 在仓库之间直接搬 blob，不落本地镜像，40GB 级镜像也不占磁盘
- **默认只搬 `linux/amd64`**，省流量省空间；需要多架构时写 `--platform=all` 或 `--platform=linux/amd64,linux/arm64`
- 目标已存在且 digest 一致时**自动跳过**，重复运行不浪费带宽
- 一次运行可推送到**多个阿里云命名空间**，命名空间在 `images.txt` 里按段落/按行指定
- 使用阿里云官方线路，国内拉取速度快

```
上游镜像仓库  →  GitHub Action Runner（skopeo copy）  →  阿里云 ACR  →  国内服务器 pull
```

## 使用方式

### 1. 准备阿里云仓库

登录阿里云容器镜像服务：https://cr.console.aliyun.com/

启用个人实例，创建一个命名空间（这个值稍后要写进 `images.txt`，例如 `[huayangtongxin]`）。

![](doc/命名空间.png)

然后到「访问凭证」页获取三个值：

| 名称 | 说明 |
| --- | --- |
| `ALIYUN_REGISTRY` | 仓库地址，如 `crpi-xxxxxxxx.cn-shanghai.personal.cr.aliyuncs.com`（控制台「访问凭证」页显示的那个域名） |
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
| `--platform=linux/arm64 nginx` | 指定架构（不写默认只搬 amd64），详见第 6 节 |
| `--tag=6897159 zlmediakit/zlmediakit@sha256:…` | 自定义目标 tag，覆盖镜像自带的 tag |
| `k8s.gcr.io/kube-state-metrics/kube-state-metrics` | 从私有仓库拉取 |
| `# 注释` | `#` 开头整行忽略 |

`images.txt` 里必须有命名空间段落或 `--space=`，否则运行时会先做预检查并直接报错，不会推到一半才失败。

**关于 tag**：不写 `--tag` 时，用镜像自带的 tag；镜像本身没有 tag（例如只给了 digest）就补 `:latest`。digest 引用建议配 `--tag=`，否则每次换 digest 都只是覆盖同一个 `latest`，无法回溯是哪个版本。

![](doc/images.png)

文件提交（push 到 `main`）后自动进入 GitHub Action 构建。只有 `images.txt` 或 `.github/workflows/docker.yaml` 变更才会触发，改文档不会触发搬运。

单个镜像失败不会中断整批：剩余镜像会继续搬运，最后 job 标记失败并打印失败清单，修好后重跑即可（已成功的镜像会再推一次，tag 相同，无副作用）。

### 4. 使用镜像

回到阿里云镜像仓库，点击任意镜像可以查看状态（也可以把仓库改成公开，拉取时免登录）。

![](doc/开始使用.png)

在国内服务器上拉取，例如：

```bash
docker pull crpi-dql3as9j0h3rd8yy.cn-shanghai.personal.cr.aliyuncs.com/huayangtongxin/alpine:3.24.1
```

- `crpi-dql3as9j0h3rd8yy.cn-shanghai.personal.cr.aliyuncs.com` 即 `ALIYUN_REGISTRY`（ACR 个人实例域名，控制台「访问凭证」页可查）
- `huayangtongxin` 即 `images.txt` 里 `[]` 中填写的命名空间
- `alpine:3.24.1` 即阿里云仓库中显示的镜像名和 tag

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

### 6. 架构

**默认只搬 `linux/amd64`**：`images.txt` 里不写 `--platform` 时，只复制 amd64 那一份子 manifest，体积最小、速度最快，也顺手避开了 ACR 不认 attestation 清单的问题。

需要其它架构时：

| 写法 | 结果 |
| --- | --- |
| `--platform=all nginx` | 完整 manifest list，所有架构都搬 |
| `--platform=linux/amd64,linux/arm64 nginx` | 只保留这两个架构的干净 index |
| `--platform=linux/arm64 nginx` | 只搬 arm64，名字带前缀 → `linux_arm64_nginx` |
| `--platform=linux/arm/v7 nginx` | 带 variant 的写法，前缀 `linux_arm_v7_` |

注意：默认的 amd64 是**单架构镜像**，如果哪天有 ARM 机器或 Apple Silicon 拉同一个 tag，会报 `no matching manifest for linux/arm64`。这时候把那一行改成 `--platform=all` 或加上 arm64 再跑一次即可。

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

### 9. 并行搬运

`images.txt` 里的镜像**每个都会开一个独立的 job 并行搬运**，不是串行排队：

```
plan job    →  解析 images.txt，做命名空间校验/重名检测，输出 matrix
sync job ×N →  每个镜像一个 runner，skopeo 比对 digest 后 copy
```

带来的好处：

- 20 个镜像从「一个接一个」变成「同时进行」，整体耗时取决于最慢的那个
- 某个镜像失败只让那一个 job 变红，其它镜像照常完成，Actions 页面上一眼能看出是哪个
- 每个 job 用独立 runner，互不影响

两个可调项在 `.github/workflows/docker.yaml` 的 `sync` job 里：

```yaml
strategy:
  fail-fast: false   # 一个失败不影响其他
  max-parallel: 5    # 同时最多几个，阿里云限速或 runner 配额紧张就调小
```

解析逻辑单独放在 [.github/scripts/plan.sh](.github/scripts/plan.sh)，可以本地预览将要生成的矩阵：

```bash
bash .github/scripts/plan.sh
```

## 常见问题

- **拉取失败 `invalid reference format`**：多半是 `images.txt` 里多了不可见字符或全角空格；plan 阶段会先报「含有非法字符」
- **推送 403 / denied**：检查 Secrets 是否为该命名空间所属账号的凭证，以及 `ALIYUN_REGISTRY` 是否与命名空间对应
- **每次都重新搬同一个镜像？** 正常情况下不会：目标 digest 与源一致会直接跳过；如果一直重复，说明上游 tag 内容真的变了，或者上一次推送被 ACR 拒绝
- **`denied: unknown manifest class`**：源镜像带了 buildx 的 attestation 清单（`os=unknown`），阿里云 ACR 不接受这种清单。工具会自动降级：按架构逐个复制，再用 `docker buildx imagetools create` 重建一份干净的 manifest list，最终的镜像依然多架构可用
- **默认只有 amd64？** 是的，为省带宽和省空间。需要多架构就把那行改成 `--platform=all`（全部）或 `--platform=linux/amd64,linux/arm64`（只要这两个），重跑一次即覆盖
