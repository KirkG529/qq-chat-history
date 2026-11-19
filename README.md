# qq-chat-history

在已登录 QQ 的 Windows x64 电脑上，让 Agent 根据用户的明文授权搜索好友或群、列出最近会话、读取最近消息或导出单个会话的全部可读历史。支持 Claude Code、Google Antigravity、Cursor 和 Codex。

## 从本仓库链接安装

将本页地址发给 Agent，并告诉它：

> 请从 https://github.com/KirkG529/qq-chat-history 安装 qq-chat-history，注册到我当前使用的 Agent，运行环境预检并告诉我结果。若需要升级或重启 QQ，请先说明影响。

### Agent 安装步骤

1. 使用用户提供的 GitHub **仓库根地址**作为下方 `$repo`。根据当前宿主选择 `claude`、`antigravity`、`cursor` 或 `codex`。如果宿主不明确，询问用户。用 Windows PowerShell 执行：

   ~~~powershell
   $repo = 'https://github.com/KirkG529/qq-chat-history'
   $harness = 'claude'  # 按实际宿主替换
   $src = Join-Path ([IO.Path]::GetTempPath()) ('qq-skill-' + [guid]::NewGuid().ToString('N'))
   git clone --depth 1 -- $repo $src
   if ($LASTEXITCODE -ne 0) { throw '克隆失败，请检查仓库地址、网络或仓库访问权限。' }
   $register = Join-Path $src 'register.ps1'
   $installed = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $register -Harness $harness
   if ($LASTEXITCODE -ne 0) { throw '注册失败，请查看上方错误。' }
   $setup = Join-Path $installed 'setup.ps1'
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup
   if ($LASTEXITCODE -ne 0) { throw '环境预检失败。' }
   ~~~

   若只对某个项目安装，在注册命令后追加 `-Project '现有项目的完整路径'`。没有 Git 时，也可从同一仓库的 **Code → Download ZIP** 下载并解压，把含有 `SKILL.md` 和 `register.ps1` 的目录赋给 `$src`，再执行注册和预检步骤。

2. 根据预检结果补齐依赖。经用户授权后，运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Install`。已有 Framework 时可传 `-FrameworkDir` 复用。QQ 安装在自定义位置时可传 `-QQExe`。首次登录由用户在自己的电脑上完成。
3. 在目标宿主开启新会话，要求“使用 qq-chat-history 查看命令帮助”以验证发现与执行。搜索会话、读取正文和导出历史的授权范围见 [SKILL.md](SKILL.md)。

本仓库根目录就是标准 Skill 目录。支持“从 GitHub 安装 Skill”的宿主也可直接选仓库根路径 `.`，名称指定为 `qq-chat-history`。宿主完成安装后，从安装目录运行 `setup.ps1` 预检即可。

## 测试

从仓库根目录运行下列测试。依赖 Windows PowerShell 5.1 和 Python 3.9+，测试使用临时目录与合成消息。

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/register.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/setup.tests.ps1
python -B -X utf8 -m unittest discover -s tests -v
~~~

## 参考代码仓库

- **QQChatExporter** 提供本 Skill 调用的本地接口，包括好友和群目录、近期会话、消息分页和单会话导出。安装脚本使用 Windows Framework 发布包 v6.4.3。[上游仓库](https://github.com/shuakami/qq-chat-exporter) · [对应版本](https://github.com/shuakami/qq-chat-exporter/releases/tag/v6.4.3)
- **NapCatQQ** 是上述 Framework 发布包使用的 QQNT 框架。安装时由 QQChatExporter 的发布包提供该组件。[上游仓库](https://github.com/NapNeko/NapCatQQ)
- **Agent Skills** 定义了技能目录和 `SKILL.md` 的通用格式，本仓库按该格式组织指令和脚本。[规范仓库](https://github.com/agentskills/agentskills)
