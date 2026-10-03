# 网易云、QQ 音乐后端与服务恢复

## 问题与边界

用户报告的是插件运行一段时间后，所有歌曲都显示暂无可用歌词。本次没有在真实
Noctalia 会话中重现整个长期失效过程，因此不能把它归因于某一个确定的运行时错误。
检查代码与实测接口确认了以下缺陷：

- QQ 旧搜索接口对测试歌曲返回 HTTP 500；桌面 MusicU 搜索可正常返回结果。
- 抓取失败后，同一首歌不会再次尝试，必须切歌或修改设置才能重新发起请求。
- 缺失异步回调时，播放器轮询没有恢复路径；歌词请求也没有服务层的超时恢复。
- 后端只尝试一个匹配结果，没有区分现场版、翻唱版，也没有利用歌曲时长排序。
- 元数据轮询总是请求完整内嵌歌词，旧拆分方式对大字符串有额外的 CPU 开销。

## 实现

`music_sources.py` 负责网易云与 QQ 的目录请求、歌曲匹配和歌词响应解码。
`lyric_sources.py` 保持原来的 JSON 请求/响应入口与统一歌词模型。

- 网易云：优先 cloud search 和 `/api/song/lyric/v1`，失败或无歌词时尝试旧接口；
  支持新旧歌曲字段、YRC 绝对逐字时间、`ytlrc` 翻译和 `yromalrc` 罗马音。
- QQ：优先 `DoSearchForQQMusicDesktop` 和 `GetPlayLyricInfo`；兼容旧搜索/歌词
  返回结构、JSONP、Base64 LRC 和未加密 QRC/XML。数值型 `qrc` 标记不会当作歌词。
- 两个源优先使用播放器媒体 URL 中明确属于该提供商的歌曲 ID；否则按照歌手、
  版本、时长排序，最多尝试三个匹配结果。没有加入账号登录或新的 Python 依赖。
- 请求共享 24 秒预算，单个 HTTP 请求最长 5 秒，CLI 设置 26 秒闹钟；HTTP 响应
  最大 2 MB。服务通过 `timeout 28s` 限制所有适配器进程。
- 自动模式在当前源失败后继续换源。整轮最长 90 秒；整轮失败后，同一首歌按
  2、4、8、16、32、60 秒间隔重试，成功后重置。
- 服务对丢失回调设置 35 秒期限；每次源请求使用独立文件与标识。切歌、换配置、
  外部推送时清理旧请求，迟到的旧回调不能覆盖当前歌词或删除下一个源的请求。
- `playerctl` 最长运行 3 秒，轮询回调期限 6 秒。连续三次轮询失败才清除当前状态。
  元数据使用线性拆分、输出限制，并且仅在启用 MPRIS 歌词源时读取内嵌歌词。
- 封面与请求缓存优先放入 `pluginDataDir()`，兼容旧宿主的目录回退。
- 保留当前已安装 1.5.x 的 Musixmatch 字幕去重行为。

## 安装到当前 Noctalia

本机检查结果：Noctalia 5.2.1；社区歌词插件 1.5.5；本仓库基线为 1.4.4。
不要用仓库里的旧界面直接覆盖已安装的新界面。

从本仓库执行：

```sh
python3 scripts/install-backend.py --dry-run
python3 scripts/install-backend.py --install
noctalia msg config-reload
noctalia msg plugins disable h465855hgg/lyrics
noctalia msg plugins enable h465855hgg/lyrics
```

安装器读取现有社区插件，创建本地覆盖副本，只替换三个后端文件；保留清单版本、
界面、资源以及 Noctalia 中按插件 ID 保存的设置。1.5.x 的显示模式属于组件设置，
安装器会取消后台对这个组件设置的读取，避免访问未声明的服务设置。

默认路径：

| 用途 | 路径 |
| --- | --- |
| 已安装社区插件 | `~/.local/state/noctalia/plugins/materialized/community/lyrics` |
| 本地覆盖副本 | `~/.local/share/noctalia/plugins/lyrics` |
| 旧本地副本备份 | `~/.local/state/noctalia/lyrics-backend-backups` |

不需要 root 权限。`timeout` 来自 coreutils，本机已经安装。
路径可通过 `--base`、`--destination`、`--backup-root` 指定，也支持 XDG/Noctalia
目录环境变量。安装器默认仅检查路径，只有 `--install` 会写文件。

[Noctalia 官方安装规则](https://docs.noctalia.dev/noctalia/plugins/development/workflow/)
规定本地插件优先于社区来源，因此无需更换现有状态栏组件 ID。
这是本地快照，社区自动更新不会更新该副本；需要更新时重新运行安装器。

安装后先把歌词源分别设为 `netease`、`qqmusic` 验证。自动模式建议将源顺序设为
`netease`、`qqmusic`、`lrclib`，其余源按需要追加。安装器不自动修改这些设置。

回退时，将本地 `lyrics` 目录移到插件目录之外，再重载配置、禁用/启用插件。
如果原来已有本地覆盖副本，则恢复安装器打印的备份目录。

## 验证记录（2026-10-03）

- 36 项 Python unittest 通过，其中服务测试实际执行 10 个 Lua 恢复场景。
- 服务场景包括同曲重试、丢失回调、迟到结果、进程拒绝、无效 JSON、配置切换、
  外部推送和手动候选选择失败；模拟超过一小时、120 次切歌并持续注入超时后仍能恢复。
- 仓库结构校验、Python 编译、Lua 语法校验、仓库 Noctalia lint 通过。
- 从本机已安装的 1.5.5 构建临时覆盖副本并执行 Noctalia lint：0 错误、0 警告。
- QQ 实测《晴天》《起风了》《夜に駆ける》返回歌词；网易云实测后两首返回歌词，
  《夜に駆ける》返回翻译。本次网易云接口没有提供《晴天》的可用歌词。
- 网易云 ID `1824020871` 的 CLI 实测返回 45 行逐字歌词，30 行带翻译与罗马音；
  每行字符时间数量与文本字符数量一致，时间序列有序。
- 真实 CLI 分别使用宿主原有网络环境和本机 `127.0.0.1:7897` 代理验证；两个环境
  都能取得网易云、QQ 测试歌词，并自动删除请求文件。

真实 Noctalia 长时间播放仍需要安装后观察。此次只修改仓库并在临时目录验证覆盖
副本，没有替换当前正在运行的插件，也没有修改用户的歌词源设置。

验证命令：

```sh
python3 tools/validate.py
noctalia plugins lint .
python3 -m py_compile lyric_sources.py music_sources.py krc_decode.py lrclib_lyric.py
python3 -m unittest discover -v
lua tests/service_recovery.lua lyrics_service.luau
```

Lua 只用于开发测试，不是插件运行依赖。没有 `lua` 时 unittest 会明确跳过服务模拟。
