# ArkDO 构建 / 签名 / 装机手册

> 目标：换一台**全新机器**也能从零把 ArkDO 打包成可安装的 HAP，并装到真机上。
> 本文**不含任何口令**——账号/口令类材料见同目录的 `build-deploy.local.md`（不入库，随机器手动带过去）。
> 最后校准：2026-10-15，Linux(WSL2)/HarmonyOS command-line-tools 26.0.0.461，实测通过。

---

## 0. 红线（先看）

1. **签名材料与口令一律不进 git。** 本仓库是公开仓库；历史上曾把签名路径与加密口令提交进 `build-profile.json5`，已于 2026-10-14 清理（提交 `32e47c5`）。
2. `build-profile.json5` **入库版本不含 `signingConfigs`**——这是故意的：没有它能构建（产出未签名 HAP），有它才签名。
3. 材料里的口令是 **DevEco 加密串**，解密依赖同目录的 `material/` 文件夹。**`*.p12 / *.cer / *.p7b` 与 `material/` 必须整套一起拷贝**，少一个都解不开（表现为 `Signature material verification failed`）。

---

## 1. 一次性准备（新机器）

### 1.1 装命令行工具链

- 需要 **HarmonyOS Command Line Tools**（与本项目验证过的版本：`26.0.0.461`，内含 `hvigor 6.26.1`、`ohpm 26.0.0.410`、`HarmonyOS SDK 26.0.0 Beta1 (API 26)`）。
- 从华为开发者官网下载 `commandline-tools-linux-x64-*.zip`（或对应平台），解压到固定目录，例如：

```bash
mkdir -p ~/.ohos-tools && cd ~/.ohos-tools
unzip commandline-tools-linux-x64-26.0.0.461.zip
# 目录形如 ~/.ohos-tools/command-line-tools/{bin,hvigor,ohpm,sdk,...}
```

- 版本自检：

```bash
cat ~/.ohos-tools/command-line-tools/version.txt
```

### 1.2 环境变量（每个新 shell 都要设，建议写进 `~/.bashrc`）

```bash
export DEVECO_SDK_HOME=$HOME/.ohos-tools/command-line-tools/sdk
export PATH=$HOME/.ohos-tools/command-line-tools/bin:$PATH
# hdc 在 SDK 里，单独加一段
export PATH=$HOME/.ohos-tools/command-line-tools/sdk/default/openharmony/toolchains:$PATH
```

自检：`hvigorw --version` 应输出 `6.26.1`；`hdc list targets` 能列出设备。

### 1.3 拉代码 + 装依赖

```bash
git clone git@github.com:andor-song/ArkDO.git && cd ArkDO
ohpm install --all      # oh_modules 不入库，全新机器必须跑一次(需网络)
```

### 1.4 放签名材料

把材料放到本机固定目录（建议 `~/.ohos/arkdo-signing/`），结构与校验见下一节。
（也可以放在仓库外的任意路径，只要 `build-profile.json5` 里的路径指对。）

---

## 2. 证书材料清单

### 2.1 调试签名（日常装机用这套）

| 文件 | 用途 | 必需 |
|---|---|---|
| `default_ArkDO_<HASH>.p12` | 应用签名私钥库（`keyAlias=debugKey`，`signAlg=SHA256withECDSA`） | ✅ |
| `default_ArkDO_<HASH>.cer` | 对应的签名证书 | ✅ |
| `default_ArkDO_<HASH>.p7b` | HarmonyOS Provision Profile（决定 bundleName / 允许安装的证书） | ✅ |
| `material/`（`ac/`、`ce/`、`fd/`） | **口令解密材料**：没有它，`build-profile.json5` 里的加密口令解不开 | ✅ |
| `default_ArkDO_<HASH>.csr` | 当初申请证书用的 CSR（只作留档，签名不用） | ❌ |

`<HASH>` 本机为 `SDWNJh3N5kn0kIyjGB8wVGYfmh7eNGHgggrG4WnHuPs=`。
**注意**：仓库历史的旧提交里出现过另一个 hash（`5LJXP0PMcJ...`），那是另一台机器的材料，已不再使用。

### 2.2 校验（拷到新机器后先核对，避免拷坏/拷少）

```bash
cd ~/.ohos/arkdo-signing
sha256sum *.p12 *.cer *.p7b
```

期望值（2026-10-15 本机实测）：

```
87af2053d1317a7c2572dde3355f5e983f27df61631522bae80087811c4659ac  default_ArkDO_SDWNJh3N5kn0kIyjGB8wVGYfmh7eNGHgggrG4WnHuPs=.p12
198c47f8da5d52e4e4362d1a46e4f91f7e72e51e2883fd8404cf65dd0fb41eec  default_ArkDO_SDWNJh3N5kn0kIyjGB8wVGYfmh7eNGHgggrG4WnHuPs=.cer
02627cc9a1b77be64f385208bd336a2260571224fa35f7616ce988e4d8d2c365  default_ArkDO_SDWNJh3N5kn0kIyjGB8wVGYfmh7eNGHgggrG4WnHuPs=.p7b
```

`material/` 目录文件清单（内容不可读，靠目录结构比对）：

```
material/ac/8dd1b68fb78349618b587192ff05809b
material/ce/84f4d292b6544affae5125304a200e44
material/fd/0/b2a0dc9a1a924fc7bfa3a822d75d1137
material/fd/1/aec84ac92fec41d18473e7198ab3242e
material/fd/2/ee94c403dd6446e086b82e984d14e9bf
```

### 2.3 发布签名（上架/正式分发用，另一套）

| 文件 | 用途 |
|---|---|
| `com.kavin.linux.do.cer` | 发布签名证书（AGC 签发） |
| `com.kavin.linux.doRelease.p7b` | 发布 Provision Profile（AGC 签发，无 UDID 限制） |
| 私钥库 | 申请该证书时用的 `.p12`（口令另存，见 local 文档） |

> 发布 profile 与 app.json5 的 `bundleName` 必须一致：`com.kavin.linux.do`。
> 不一致会报 `bundleName ... does not match the generated SigningConfigs`。

### 2.4 材料丢了怎么办

- 调试材料：**DevEco Studio** → `File → Project Structure → Signing Configs` → 勾选自动签名（需华为开发者账号登录），它会重新生成 `.p12/.cer/.p7b`，并把配置写回 `build-profile.json5`。
- 发布材料：AGC 控制台重新签发证书与 profile（用原来的 CSR 或新 CSR）。
- 材料轮换后：**同步更新** `build-profile.json5`（本机）与 local 文档，并把新哈希写回本文第 2.1/2.2 节。

---

## 3. 把签名配置接回构建

入库的 `build-profile.json5` 里没有 `signingConfigs`。在需要签名的新机器上：

1. 在 `app` 对象内加入 `signingConfigs`（**具体口令见 `build-deploy.local.md`**）：

```json5
"signingConfigs": [
  {
    "name": "default",
    "type": "HarmonyOS",
    "material": {
      "certpath": "/home/<你>/.ohos/arkdo-signing/default_ArkDO_SDWNJh3N5kn0kIyjGB8wVGYfmh7eNGHgggrG4WnHuPs=.cer",
      "keyAlias": "debugKey",
      "keyPassword": "<加密口令>",
      "profile": "/home/<你>/.ohos/arkdo-signing/default_ArkDO_SDWNJh3N5kn0kIyjGB8wVGYfmh7eNGHgggrG4WnHuPs=.p7b",
      "signAlg": "SHA256withECDSA",
      "storeFile": "/home/<你>/.ohos/arkdo-signing/default_ArkDO_SDWNJh3N5kn0kIyjGB8wVGYfmh7eNGHgggrG4WnHuPs=.p12",
      "storePassword": "<加密口令>"
    }
  }
],
```

2. 在 `app.products[0]` 里加回引用：`"signingConfig": "default",`
3. 让这个本地改动**不污染 git**（本机做法）：

```bash
git update-index --skip-worktree build-profile.json5     # 之后 git status 不再显示它
# 需要改仓库里那份(如升 SDK)时先: git update-index --no-skip-worktree build-profile.json5
```

> ⚠️ 加了 `skip-worktree` 后，`git status` **看不到**这个文件的本地改动。别的机器/别人拉下来仍是干净的、不含签名的版本。

---

## 4. 构建

```bash
cd ArkDO
export DEVECO_SDK_HOME=$HOME/.ohos-tools/command-line-tools/sdk
export PATH=$HOME/.ohos-tools/command-line-tools/bin:$PATH

# 调试包（日常装机）
hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon

# 发布包（用发布材料时改 build-profile.json5 指向发布那套）
hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=release --no-daemon
```

产物：

```
entry/build/default/outputs/default/entry-default-signed.hap     # 有签名配置时
entry/build/default/outputs/default/entry-default-unsigned.hap   # 无签名配置时
```

校验产物里的版本号：

```bash
unzip -p entry/build/default/outputs/default/entry-default-signed.hap module.json \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['app']['versionName'],d['app']['versionCode'])"
```

### 只做类型检查 / 编译测试代码（不开设备）

```bash
hvigorw entry:default@UnitTestArkTS --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
```

### 常见报错对照

| 报错 | 原因与处置 |
|---|---|
| `Invalid storeFile value / must be included in 'C:\...'` | 签名配置指向别的机器的不存在路径 → 改成新机器材料路径 |
| `Signature material verification failed, as: Unsupported state or unable to authenticate data` | 加密口令与 `material/` 不配套（多半是只拷了 p12 没拷 material，或用了别套材料的口令）→ 整套重拷 |
| `The ASSET ...` / `bundleName ... does not match the generated SigningConfigs` | profile 与 `AppScope/app.json5` 的 `bundleName` 不一致 → 换对应站点的 profile |
| `ArkTS Compiler Error: ... not assignable / Cannot find name` | 真编译错误（本机无法用别的手段替代）→ 按报错行修 |

---

## 5. 装机

前置：设备开启**开发者模式 + USB 调试**，数据线连上（WSL 下需要 USB 直通或已能识别）。

```bash
hdc list targets                                  # 应打印设备序列号(如 3KP0124921000093)
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap   # -r = 覆盖安装,保留应用数据
hdc uninstall com.kavin.linux.do                  # 需要清数据重装时
hdc shell aa start -a EntryAbility -b com.kavin.linux.do                      # 启动
```

**注意（踩过的坑）**：

- `aa start` 在**锁屏**时会失败：`10106102 The device screen is locked`——鸿蒙开发者模式下无法自动解锁，**先解锁屏幕**再启动；测试期间建议开"充电时屏幕不休眠"。
- 装未签名 HAP 必失败：`9568320 error: no signature file`。
- 同 `versionCode` 也能 `-r` 覆盖（本次实测），但**发版应递增**（见第 6 节）。
- 覆盖安装保留数据（含登录态）；跨签名/换证书安装需先卸载，数据会清空。

---

## 6. 发版节奏（每次对外发版的固定动作）

1. `AppScope/app.json5`：`versionCode` +1（形如 `1000007`）、`versionName` 形如 `1.0.7`。
2. `CHANGELOG.md`：把 `## [未发布]` 改成 `## [<版本>] - <日期>`，内容按 修复/新增/变更 归类。
3. 构建 + 装机自测（第 4、5 节）。
4. `git add` → `git commit -m "chore: <版本> 版本递增 + CHANGELOG(<要点>)"` → `git push origin main`。

---

## 7. 真机排查速查

```bash
D=/data/app/el2/100/base/com.kavin.linux.do/haps/entry/files/app_logs
hdc shell "ls -la $D"                      # arkdo.log + arkdo.1..9.log（留 10 份 ≈10MB）
hdc file recv "$D/arkdo.log" /tmp/arkdo.log
```

- **一键网络快照**：App 内 `设置 → 诊断日志 → 网络快照`——采集 DoH 实测、直连实测、`_t`/`cf_clearance` 状态与最近关键日志，可复制/随日志导出。网络类问题（刷不出来/掉登录/过盾）先看它。
- 登录凭据在**系统密钥库**（Asset Store），不在偏好库；偏好库里只留身份快照（用户名/头像）。
- 会话相关日志关键字：`current user checked loggedIn=`、`verdict=`、`restoring auth cookie from secure store`、`network changed`、`challenge required`。
- `hdc shell uitest dumpLayout -p /data/local/tmp/l.json` + `hdc file recv` 可读屏上文案（自动化点击用 `uitest uiInput click X Y`）。

---

## 8. 本机验证过的工具链组合（复现用）

| 组件 | 版本 |
|---|---|
| HarmonyOS Command Line Tools | 26.0.0.461（linux-x64） |
| hvigor | 6.26.1 |
| ohpm | 26.0.0.410 |
| HarmonyOS SDK | 26.0.0 Beta1 / API 26（`Ohos_sdk_public 26.0.0.23`） |
| JDK（仅签名工具需要） | OpenJDK 21 |
| 运行环境 | WSL2 上的 Linux 6.6（Windows 11 宿主） |
| 真机 | PLU-AL10 / HarmonyOS 7.0.0.111 |

> 结论：**不需要 Windows/DevEco 也能出签名包**——上面这套 CLI 工具链 + 第 2 节材料即可全程完成构建、签名、装机、抓日志。
