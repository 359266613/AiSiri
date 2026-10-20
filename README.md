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
- 仅复用同轮观察到的原生 `SAUIAddViews` 的 turn、时间和展示参数。
- 拿不到原生上下文时最多等待 8 秒，然后放弃并记录原因。
- 播报默认关闭；开启后只设置 `speakableText`，是否实际播报需要真机确认。
- 关闭 Siri、开始新请求或修改设置会使旧测试结果失效。
- 不将识别原文、回答原文、音频、会话标识或密钥写入日志。

`answer-submitted` 只表示接口调用返回，不表示界面已经呈现或播报成功。

## 目录

```text
Hooks/AxsAiSiriSessionHooks.xm  定向 hook、延迟安装、会话生命周期
Headers/AxsAiSiriPrivate.h           实际编译使用的最小声明
Headers/AF*.h, SA*.h           用户提供的原始导出文件，保持不变
Sources/AxsAiSiriProbeManager.m      固定回答验证与原生上下文复用
Sources/AxsAiSiriTrigger.m           前缀匹配
Sources/AxsAiSiriConfig.m            共享设置读写
Sources/AxsAiSiriJailbreakPath.h      用户数据路径解析
Sources/AxsAiSiriDiagnostics.m       本地有限长度诊断与统一日志
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
3. 关闭现有 Siri 界面，再重新唤醒，说「问 AI，你好」。
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
| `final-recognition` | 已收到可读取的最终结果，记录长度和前缀是否匹配 |
| `unsupported-recognition` | 实际对象不支持 `oneBestTranscript`，记录其类名 |
| `invalid-transcript` | 转写返回值不是字符串 |
| `invalid-reply` | 固定回答为空或超过 512 个 UTF-16 代码单元 |
| `probe-timeout` | 等待上下文超时，附视图、turn 和时间是否可用 |
| `answer-submitted` | 已尝试投递，必须人工确认实际画面与声音 |
| `presentation-unavailable` | 回答对象工厂或投递入口不可用 |
| `transcript-exception` / `presentation-exception` | 私有接口抛出异常，仅记录异常名称 |

日志按宿主分文件，位于 `/var/mobile/Library/Logs/AiSiri/`，
每个宿主最多保留本次进程的最近 120 条事件。文件不可写时仍尝试使用统一日志，
子系统为 `com.axs.aisiri`；面板无法读取统一日志，需用设备日志工具查看。
日志文件可能保留上次启动的信息，反馈时注意时间与 PID。

## 已知边界

没有取消 Apple 后端请求，没有拦截其执行的系统操作，也没有实现大模型请求。
原生回调线程、回答可见性、音频会话行为和实际宿主只能在你的设备上确认。
macOS 测试使用假的 Siri 对象，只验证本地逻辑，不证明私有 API 可用。
拿到真机验证结果后，再决定补充接口、调整投递入口或接入 OpenAI。

出现异常时先关闭 AiSiri；若无法进入设置，用越狱环境提供的安全模式卸载。
