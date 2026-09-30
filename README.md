# Agents Anywhere × DSH 官方壳：手机/桌面端连不上的修复记录

> **环境（实测版本）**：Agents Anywhere 桌面端 `2.0.0`（内置 connector `anywhere-cli 0.1.7.2`）＋ DSH 官方壳 `0.2.0-rc.2` ＋ 插件 `@agents-anywhere/dsh-bridge-next 2.0.2`
> **症状**：设备能连上、会话列表也有，但**内容永远同步不过来**，连接器每秒重订阅一次，日志刷 `ValueError`
> **修复**：`patch/connector-projection-v3.patch`（两行版本门禁，把 `!= 2` 放宽为 `not in (2, 3)`）

**English TL;DR** — The DSH bridge plugin bumped its history *projection version* from 2 to 3, while the connector bundled in Agents Anywhere Desktop 2.0.0 still hard-requires `projectionVersion == 2`. Every `runtime.sync.subscribe` therefore raises `ValueError("Unsupported DSH projection version")` and the client resubscribes in a loop: devices pair, but no content ever syncs. The fix is a two-line patch to the connector (`!= 2` → `not in (2, 3)`), applied by `patch/apply-connector-patch.ps1`. Nothing to do with the network, the token, or the bridge not starting.

## 1. 症状长什么样

- 桌面端、手机端都能连上，会话列表能出来，**内容停在原地**（后续消息不更新）
- connector 日志（`%APPDATA%\Agents Anywhere\logs\connector-*.jsonl`）里每秒一条：
  ```
  DSH event sync interrupted; resubscribing for complete history calibration (ValueError)
  ```
- 桥侧日志（`~\.agents-anywhere\dsh-bridge-next\logs\dsh-runtime.jsonl`）呈同样的节拍：`sync.started` → `sync.batch`（只有第一页）→ `sync.stopped waitingAck=1`，循环往复
- **连接是好的**：`ping` 通、`session.list` 有返回、端口在监听。别被"同步不动"误导成网络问题

## 2. 根因：投影版本（projection version）错配

DSH 桥的历史同步协议带一个**投影版本号**：

| 侧 | 版本 | 行为 |
|---|---|---|
| 插件 `dsh-bridge-next` | **3**（2026-09-25 起由 2 升到 3，变更说明："投影版本升为 3，旧检查点触发快照重建"） | 在 `runtime.sync.subscribe` 与每个 `sync.batch` 里发 `projectionVersion: 3` |
| AA 桌面端 2.0.0 内置 connector | **只认 2** | `if subscription.get("projectionVersion") != 2: raise ValueError(...)` |

于是每次订阅都当场抛异常 → 客户端重订阅 → 再抛 → **每秒一次的确定性死循环**。因为订阅对象已经被替换掉，`sync.ack` 永远不会发生，服务端也就一直认为第一页没被确认——表现就是"连上了但什么都不动"。

> 结论：这是**发布节奏不一致**，不是任何一侧的崩溃。插件主分支已升到 3，而 AA 桌面端 2.0.0 的 connector 还停在只认 2 的状态（npm 上插件也只发到 2.0.1）。

## 3. 修复

### 3.1 补丁内容

`patch/connector-projection-v3.patch`——只改 `connector/runtimes/dsh/bridge/sync.py` 的两行：

```diff
-            if subscription.get("projectionVersion") != 2:
+            if subscription.get("projectionVersion") not in (2, 3):
                 raise ValueError("Unsupported DSH projection version")
...
-                if batch.get("projectionVersion") != 2 or not isinstance(batch.get("operations"), list) or not batch["operations"]:
+                if batch.get("projectionVersion") not in (2, 3) or not isinstance(batch.get("operations"), list) or not batch["operations"]:
                     raise ValueError("Invalid DSH event batch")
```

兼容 2 与 3 两种投影；其它校验（`streamId`、`batchSeq` 顺序、`operations` 形状）一个字没动，所以**不会掩盖真正的不一致**——版本既不是 2 也不是 3 时照旧报错。

### 3.2 怎么打

自动（推荐，会先比对哈希再动手、并留一份 `.bak`）：

```powershell
powershell -File patch\apply-connector-patch.ps1                 # 自动定位 AA 安装目录
powershell -File patch\apply-connector-patch.ps1 -AppRoot "D:\Apps\Agents Anywhere"
powershell -File patch\apply-connector-patch.ps1 -Revert          # 还原
```

手动（用 git）：

```powershell
cd "<AA 安装目录>\resources\connector"
git apply -p1 --check "<本仓库>\patch\connector-projection-v3.patch"   # 先 dry-run
git apply -p1 "<本仓库>\patch\connector-projection-v3.patch"
```

改完**重启 Agents Anywhere 桌面端**（connector 是随应用启动的 Python 进程，不重启不生效）。

### 3.3 哈希（用于确认你手上的版本对不对）

| 状态 | `connector/runtimes/dsh/bridge/sync.py` 的 SHA256 |
|---|---|
| 原始（AA 桌面端 2.0.0 内置，10514 字节） | `DB88916C91983584F8748404176B77F2AEF001FE65618C5015CBABCBDC218AB0` |
| 打过本补丁 | `723B9BEDA7B67885D01C9CA9E8D5CECC16D4940CB9B57C29A0544BCEF369A39A` |

本仓库的补丁**已在原始文件上验证**：`git apply -p1` 之后结果与上表第二行逐字节一致。若你的文件哈希两者都不是（例如 AA 已经升级），脚本会拒绝动手，请先核对新版源码再决定。

## 4. 验收（打完补丁应该看到什么）

- connector 日志里 `ValueError` 停止增长（记下最后一条的时间戳，重启后应不再出现新的）
- 桥侧 `sync.ack` 稳定跟随 `sync.batch`（实测约 450 条/分钟），`snapshot.completed` / `snapshot.commit` 成对出现，全程 0 error / 0 warn
- 桌面端与手机端会话**内容正常更新**（这是最终判据，不是日志好看）

## 5. 顺带：官方壳怎么把 AA 接起来（完整链路）

社区版 DSH 壳把 Agents Anywhere **内置**在安装包里，换成官方壳后侧栏没有「远程控制」——因为**它是插件，不是壳的功能**。补上：

```powershell
dsh plugin --profile desktop add @agents-anywhere/dsh-bridge-next
```

官方壳有 **peer 硬门禁**，版本对不上会直接拒绝安装，例如：

```
installation rejected: Plugin @agents-anywhere/dsh-bridge-next@2.0.1 is incompatible with
dsh 0.2.0-rc.2: peerDependencies {"@deepseek-ai/dsh-typert-protocol":"0.1.7-rc.2"}.
Running it may cause crashes or data loss.
dsh: nothing was installed.
```

出路有两条：

- **路线 A（最快）**：知情豁免安装 npm 上的版本
  ```powershell
  dsh plugin --profile desktop allow-version @agents-anywhere/dsh-bridge-next@2.0.1 --dsh-version 0.2.0-rc.2 --accept-risk
  ```
- **路线 B（本记录实际走的）**：从上游主分支构建再 `link` 进 profile——主分支的 peer 声明已跟上官方壳。装完把 profile 的 `package.json` 依赖指向本地构建产物（`link:<path>`）即可

**装完不需要重启壳**：插件会被**热加载**进正在运行的壳，端点文件当场生成：

```
~\.dsh\agents-anywhere\bridge\endpoint.json     # {version, host, port, token, pid}
```

侧栏「远程控制」没出现时，**只需刷新渲染进程**，不必重启应用。

**接线验收**（三者齐了才算通）：

1. 上面的 endpoint 文件生成，且 `host` 是 `127.0.0.1`、端口在监听
2. 按上游协议对那个端口发 `initialize`（带 endpoint 里的 token）→ `ping`、`runtime.getCapabilities`、`session.list` 都有正常返回
3. connector 日志不再报 `runtime_unavailable`

> ⚠️ 打通 AA 靠的正是第 3 节那个 connector 补丁：**即使插件装好了，不补 connector，症状依然是"连上但不同步"**。

## 6. 注意事项

- **AA 桌面端一升级，connector 会被整包覆盖**，补丁随之消失——症状复发时，第一件事就是查 `sync.py` 里那两处门禁是不是又变回 `!= 2`
- 插件侧一旦把投影版本再往上抬（4、5…），本补丁同样要跟着放宽；反过来，若 AA 官方 connector 追上了 3，本补丁即可退休
- npm 上的插件版本可能落后于上游主分支（写这份记录时 npm 只有 2.0.0 / 2.0.1，主分支已是 2.0.2）；版本门禁报错时先看 `package.json` 的 `peerDependencies` 再决定走 A 还是 B

## 7. 这个仓库里有什么 / 没有什么

- **有**：现象与根因、两行补丁（unified diff）、带哈希校验的应用/还原脚本、验收判据
- **没有**：上游源码的整份拷贝。connector 的许可证未随安装包声明，本仓库只发布 diff 与说明，不复制上游文件；需要原文请从你自己的 AA 安装目录或上游仓库取
- 涉及 `dsh-bridge-next`（MIT）的部分只做引用与链接

## 致谢

- [anywhere-labs/Agents-Anywhere](https://github.com/anywhere-labs/Agents-Anywhere)——Agents Anywhere 本体与 `dsh-bridge-next` 插件
- DSH（DeepSeek Harness）——官方壳与插件机制

## 许可

本仓库内的文字与脚本以 [MIT](LICENSE) 发布；上游项目版权归其各自作者所有。
