# AiSiri 本地验证版

面向 iPhone 14 Pro、iOS 16.5、Dopamine Rootless 的 Theos 插件工程。
本阶段只验证 Siri 识别回调及原生回答投递，不连接 OpenAI，也不需要 API Key。
尚未完成真机验证，不能视为已经可用的 Siri 替代品。

## 当前行为

- 默认关闭；设置面板开启后才处理最终识别文本。
- 默认前缀为「问AI」，大小写与前缀内部空白不敏感。
- 问句必须从前缀开始，且前缀后有实际内容；空前缀不会接管所有问句。
- 匹配后尝试追加固定回答，每轮最多投递一次。
- 原生 Siri 处理仍保留，因此原生回答与测试回答可能同时出现。
- 优先复用同轮原生 `SAUIAddViews` 实际经过的
  `siriSessionDidReceiveAddViewsCommand:completion:` 展示入口及展示参数；
  该入口不需要 turn 或时间，不再因等待旧执行入口而超时。
- 旧执行路径仍仅使用实际观察到的 turn 和时间，不伪造参数。
- 拿不到原生上下文时最多等待 8 秒，然后放弃并记录原因。
- 监听公开执行、命令接收、内部执行及批量执行路径；接收与批量入口仅用于诊断，
  不会猜测 turn 或时间，内部执行入口观察到完整原生参数后也可用于投递。
- 从会话的 `delegate` / `localDelegate` 读取运行时类名及命令方法；
  仅监听协议声明且签名兼容的对象参数回调，原始参数和 completion 原样转发。
- delegate 投递必须同时满足：原生命令已在本轮收到、实际转交给当前 delegate、
  原生 completion 签名受支持。使用独立 completion，不改原生命令，也不复用其回调。
- 播报默认关闭；开启后只设置 `speakableText`，是否实际播报需要真机确认。
- 关闭 Siri、开始新请求或修改设置会使旧测试结果失效。
- 默认不将识别原文、回答原文、音频、会话标识或密钥写入日志。
  仅在面板确认「记录下一次测试文本」后，两分钟内的下一次有效识别原文会写入
  本地有限长度诊断，不写入统一日志，并随「复制诊断」一起导出。

`answer-submitted` 只表示接口调用返回，不表示界面已经呈现或播报成功。

## 目录

```text
Hooks/AxsAiSiriSessionHooks.xm  定向 hook、延迟安装、会话生命周期
Headers/AxsAiSiriPrivate.h           实际编译使用的最小声明
Headers/AF*.h, SA*.h           用户提供的原始导出文件，保持不变
Sources/AxsAiSiriProbeManager.m      固定回答验证与原生上下文复用
Sources/AxsAiSiriTrigger.m           前缀匹配
Sources/AxsAiSiriTranscript.m        AFSpeechRecognition / ACE 识别文本提取
Sources/AxsAiSiriConfig.m            共享设置读写
Sources/AxsAiSiriJailbreakPath.h      用户数据路径解析
Sources/AxsAiSiriDiagnostics.m       本地有限长度诊断与统一日志
Sources/AxsAiSiriDelegateProbe.m     delegate 方法发现、签名校验与定向监听
AiSiriprefs/                    PreferenceLoader 设置面板
layout/                        面板注册入口
Tests/                         静态检查与 macOS Objective-C 测试
```

本插件自有的类、C 函数、常量、状态键统一使用 `AxsAiSiri` 前缀，
设置面板自有 selector 和属性使用 `axsAiSiri` 前缀，避免与其他 Axs 插件共享运行时名称。
Apple 私有类与必须覆写的系统方法名称不变。设置域仍为 `com.axs.aisiri`，已有配置保留。

## 编译

需要 macOS、可用的 Xcode 命令行工具、Theos、兼容的 iOS SDK，
以及 Theos 的 Preferences 头文件/链接桩。工程同时生成 arm64 和 arm64e。
本工程的构建脚本要求 macOS，不承诺其他 arm64e 工具链的兼容性。

```bash
export THEOS=/path/to/theos
bash Tests/run-macos.sh
bash build.sh
```

如果 Theos 默认选择的 SDK 不合适，可显式指定已安装版本：

```bash
bash build.sh TARGET=iphone:clang:16.5:16.5
```

产物位于 `packages/`。Theos Rootless scheme 负责将架构改为
`iphoneos-arm64` 并添加 `/var/jb` 安装前缀，不能手动给 `layout/` 再加一层前缀。
此阶段只支持 Rootless；不要将产物用于 Rootful 或 Roothide。

Windows 可先运行工程静态检查：

```powershell
.\Tests\Validate-Project.ps1
```

静态检查不等于 Objective-C 编译、单元测试或真机测试。

## 安装与验证

1. 将编译出的 deb 在手机上交给 Sileo 安装，按提示重新载入用户空间。
2. 在设置中打开 AiSiri。首次先保持播报关闭。
3. 关闭现有 Siri 界面，先说「嘿 Siri」，等它开始听取后再说「问 AI，你好」。
4. 观察是否出现「AiSiri 本地测试回答。这不是 OpenAI 生成的内容。」。
5. 再测试一个不带前缀的普通 Siri 问句，确认其仍正常工作。
6. 确认文字可见后再单独测试播报，不要把投递日志当作播报成功。
7. 无论成功或失败，在设置面板点击「复制诊断」，把内容反馈给开发者。

如果 Siri 实际识别出「问爱」等其他文字，可将前缀改为「测试回答」，
然后说「测试回答，你好」。插件不会自动把同音词归为触发词。

## 诊断

当前只注入两个候选宿主：`com.apple.springboard`、`com.apple.SiriViewService`。
实际承载 `AFUISiriSession` 的进程仍需通过真机日志确认，不进行全局注入。

| 事件 | 含义 |
| --- | --- |
| `probe-loaded` | 动态库已在某个候选宿主加载，附进程与系统信息 |
| `hooks-installed` | 会话类及所有必要方法存在，已安装 hook |
| `session-class-not-hooked` | 10 秒内尚未安装 hook，需要检查宿主或类加载 |
| `hook-method-missing` | 方法声明与运行时不匹配，未安装整组 hook |
| `command-hook-installed` / `command-hook-unavailable` | 新增命令路径已安装或不存在，不影响核心 hook |
| `native-command-path` | 命令路径与类名，每轮最多 16 种组合，不记录命令内容 |
| `delegate-inventory` | delegate 类名、协议候选方法、类型编码及是否安装监听 |
| `delegate-dispatch` | 本轮经过 `_performBlockWithDelegate:`，不包装或调用其 block |
| `delegate-command-path` | 实际 delegate 回调、参数类名及是否含 `SAUIAddViews` |
| `delegate-binding` | 绑定与投递检查的 `stage`、`reason`，只记录状态和类名 |
| `final-recognition` | 已收到可读取的最终结果，记录长度和前缀是否匹配 |
| `unsupported-recognition` | 实际对象既不提供直接转写，也不提供 ACE recognition 入口 |
| `invalid-transcript` | 转写为空、ACE 结构不完整或超过长度限制 |
| `invalid-reply` | 固定回答为空或超过 512 个 UTF-16 代码单元 |
| `probe-timeout` | 等待上下文超时，附视图、turn 和时间是否可用 |
| `probe-session-ended` | 已识别但尚未投递时会话结束，`replyPending` 表示是否已排入回答 |
| `answer-submitted` | 已尝试投递，必须人工确认实际画面与声音 |
| `answer-delivery-completed` | 独立投递回调已返回，不代表已经显示或播报 |
| `delegate-completion-unsupported` | 无法确认原生 completion 签名，不猜测回调 ABI |
| `presentation-unavailable` | 回答对象工厂或投递入口不可用 |
| `transcript-exception` / `presentation-exception` | 私有接口抛出异常，仅记录异常名称 |
| `context-exception` | 读取原生展示参数时异常，仅记录路径和异常名称 |

日志按宿主分文件，位于 `/var/mobile/Library/Logs/AiSiri/`，
每个宿主最多保留本次进程的最近 120 条事件。文件不可写时仍尝试使用统一日志，
子系统为 `com.axs.aisiri`；面板无法读取统一日志，需用设备日志工具查看。
日志文件可能保留上次启动的信息，反馈时注意时间与 PID。

delegate 绑定诊断版的复制标题为 `delegate-binding-v6`。更新后保持现有前缀，
重新唤起 Siri 并测试一次，等待至少 10 秒再复制诊断。
`native-command-path` 的 `path` 区分 `received-command`、`public-execute`、
`internal-execute` 和 `batch-execute`；`answer-submitted.contextSource`
记录实际复用上下文的路径，新的展示入口记为 `delegate-add-views`。
看到命令接收不等于已经拿到可投递的上下文。

`delegate-inventory.methods` 的 `protocolDeclared`、`signatureSupported` 和
`hookInstalled` 区分「协议确认」「签名兼容」「已监听」。
仅支持返回 `void`、1 至 4 个对象参数的协议命令回调；其他方法只报告，不猜测 ABI。
不记录参数内容、对象地址或会话标识。每个进程最多发现 8 个角色/类组合、
安装 24 个通用回调监听，另为展示入口保留至总计 32 个的额度；
清单与回调摘要按设置周期去重，仍受 120 条日志总上限约束。
completion 签名通过 libclosure 的 `_Block_signature` 读取，仅接受返回 `void`、
无参数或单个对象响应的 block；不可用或签名不符时放弃该路径。

本版只补齐绑定检查诊断，不宣称已经解决真机投递失败，也不放宽投递条件。
重点查看 `delegate-binding`：

- `receive/command-linked`：已在收到的原生命令上写入并读回关联。
- `callback/command-context-missing`：回调命令没有该关联；仅说明关联不存在，
  不能单凭此项断定命令被复制。
- `callback/session-released`：有关联，但其弱引用的 session 已释放。
- `callback/delegate-mismatch`：回调接收者与当前 delegate 不是同一个对象，
  附两者类名，不记录地址。
- `callback/session-inactive` / `generation-mismatch`：会话结束或命令属于旧请求。
- `callback/completion-unsupported` / `metadata-exception`：回调签名或展示参数检查失败。
- `callback/context-ready`：绑定成功；后续 `present` / `submit` 阶段说明投递等待或失效原因。

`delegate-binding` 每个设置周期最多保留 32 种阶段/原因组合，同类事件只记录首次；
不记录命令标识、会话标识、对象地址或参数原文。更改设置后清空该去重集合。

## 已知边界

没有取消 Apple 后端请求，没有拦截其执行的系统操作，也没有实现大模型请求。
原生回调线程、回答可见性、音频会话行为和实际宿主只能在你的设备上确认。
macOS 测试使用假的 Siri 对象，只验证本地逻辑，不证明私有 API 可用。
拿到真机验证结果后，再决定补充接口、调整投递入口或接入 OpenAI。

识别兼容：直接转写使用 `oneBestTranscript`；iOS 16.5 实际回调中的
`SASSpeechRecognized` 沿 `recognition.phrases[].interpretations[0].tokens[]`
提取文本，保留词元空格标记，不扫描其他候选来触发插件。
`final-recognition` 的 `path` 字段区分两种提取路径，仍不记录识别原文。
其 `configuredPrefix` 和 `prefixSource` 分别记录运行时读到的前缀与设置来源。
复制诊断末尾另附面板读取的已保存前缀，便于检查跨进程设置是否一致。
前缀不匹配时可主动确认「记录下一次测试文本」，仅说测试内容，再复制诊断。
该请求只在当前宿主进程消费一次；若两分钟内重启宿主进程，可能再次消费尚未过期的请求。
测试原文随日志条目轮换而移除，旧日志文件在此之前仍可能包含该文本。

出现异常时先关闭 AiSiri；若无法进入设置，用越狱环境提供的安全模式卸载。
