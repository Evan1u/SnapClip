# SnapClip 自动更新脚本实施规格

## 目标

为已经安装在 `/Applications/SnapClip.app` 的用户提供一个可审计、可回滚的命令行更新入口。脚本自动发现 `Evan1u/SnapClip` 最新可用的 GitHub Release，下载 Apple Silicon ZIP，完成完整性与应用包校验后替换现有应用。

本次只增加显式运行的本地脚本，不让 SnapClip 在后台联网，不增加常驻进程，也不在应用启动时静默更新。

## 交付物

- `scripts/update-snapclip.sh`：正式更新入口。
- 脚本内置 `--check`、`--dry-run`、`--help`，默认执行更新。
- 更新 README 的安装说明，给出检查与更新命令。

## 命令约定

```sh
./scripts/update-snapclip.sh --check
./scripts/update-snapclip.sh --dry-run
./scripts/update-snapclip.sh
```

- `--check`：只报告本地版本和远端目标版本，不下载、不退出应用、不写入 `/Applications`。
- `--dry-run`：完成版本发现和资产选择，打印后续动作，但不下载、不替换应用。
- 无参数：发现较新版本后下载、验证、替换并重新启动；已是最新版时正常退出。
- 可用环境变量 `SNAPCLIP_APP_PATH` 覆盖默认安装路径，便于测试和非标准安装；不复用 `HOME` 等系统变量。
- `--help`、已是最新版和 `--check` 均返回 `0`；未知参数、互斥参数组合、校验失败或更新失败返回非零。`--check` 发现新版仍返回 `0`，以输出文本表达状态。

## Release 与资产选择

1. 使用 GitHub Releases API 获取发布列表，而不是 `/releases/latest`；后者会忽略 SnapClip 当前使用的 Pre-release。按 API `Link` 头翻页，最多读取 10 页；HTTP 非成功、限流或数据不完整均安全失败。
2. 忽略 Draft，正式版和 Pre-release 使用同一选择规则。只接受 `vMAJOR.MINOR.PATCH` tag，取三段数字语义上最高的版本，而不是依赖 API 返回顺序。
3. 选中 tag `vX.Y.Z` 后，只接受唯一的 `SnapClip-vX.Y.Z-arm64.zip` 资产；没有或出现重名资产均失败。不自动安装 DMG，也不接受其他命名或架构。
4. 从已安装应用的 `CFBundleShortVersionString` 读取本地版本。tag 去掉前导 `v` 后必须与应用版本完全相同。三段版本数字不允许无意义前导零，每段最多 9 位；比较时先比较字符串长度、再按字典序比较，避免 shell 整数溢出。
5. 目标版本不高于本地版本时不替换。允许后续增加显式的 `--force`，但本次不提供隐式降级。

## 完整性与身份校验

更新包在碰触现有应用前必须通过以下检查：

1. HTTPS 下载成功，且下载结果是普通文件。
2. GitHub Release Asset 元数据必须提供 `sha256:` digest；本地 `shasum -a 256` 必须完全一致。缺少 digest 时安全失败，不提供跳过开关。
3. `ditto` 解压后顶层必须只有一个普通目录 `SnapClip.app`；应用包及其关键路径不得是符号链接，拒绝路径逃逸和异常顶层文件。
4. Bundle ID 必须是 `com.local.SnapClip`，`CFBundleShortVersionString` 必须等于 tag 去掉 `v` 后的版本。主可执行文件必须包含 `arm64`，允许 universal binary；`LSMinimumSystemVersion` 必须不高于当前运行系统版本。
5. 现有应用也必须先通过 Bundle ID、Info.plist、架构和签名检查；此脚本不承担首次安装或修复损坏安装。
6. 新旧应用都运行 `codesign --verify --deep --strict`。正常成功时继续；针对当前未公证 Apple Development Pre-release，仅当失败输出严格只包含 `CSSMERR_TP_NOT_TRUSTED` 及架构提示时，才把它视为“签名结构完整但私有信任链不受系统信任”，其他资源、可执行文件或 requirement 错误一律失败。随后提取并比较非空的 `TeamIdentifier` 与 designated requirement；任一字段无法解析或不一致时中止，防止签名主体变化导致 TCC 身份漂移。
7. 保持现有 Apple Development、未公证 Pre-release 发布约定，不把 Gatekeeper 公证校验误当作代码签名校验。

## 事务式替换与回滚

1. 所有下载和首次解压发生在 `mktemp -d` 创建的临时目录，退出时自动清理。
2. 用目标绝对路径的 SHA-256 建立 `/tmp` 互斥锁。锁内记录 PID；活跃锁直接退出，确认 PID 不存在后才清理残留锁。脚本的退出 trap 只删除自己持有的锁。
3. `SNAPCLIP_APP_PATH` 必须是绝对路径、以 `.app` 结尾、目标存在且不是符号链接；解析后的父目录和应用路径必须保持一致。提权前再次核对目标身份，禁止把任意路径交给 `sudo`。
4. 新应用完成全部预检后，用内嵌 JXA 调用 `NSWorkspace.shared.runningApplications`，按 `executableURL.standardizedFileURL.path` 与目标 `Contents/MacOS/SnapClip` 的标准绝对路径完全相等来取得 PID；路径作为数据传入，不解析 `ps` 文本，因此支持空格和同 Bundle ID 的多个副本。逐个调用 `NSRunningApplication.terminate()` 并等待最多 10 秒，超时则停止，不按进程名终止其他副本。
5. 用 `ditto --rsrc --extattr --acl` 把已验证的新应用复制到目标父目录中的唯一 sibling staging 路径，再次完成 Bundle、架构、版本、签名与签名主体检查。禁止 staging 树内存在任何符号链接；`Info.plist`、`Contents/MacOS/SnapClip` 和 `_CodeSignature/CodeResources` 必须是位于包内的普通文件。脚本不递归 `chown` 或 `chmod`，避免提权操作跟随异常链接。这样最终移动发生在同一卷。
6. 建立唯一 sibling backup 路径，按“旧目标 → backup、staging → 目标”顺序重命名。两次重命名不是单一原子事务，因此脚本通过状态标记和 `EXIT`/`HUP`/`INT`/`TERM` trap 管理恢复：只要 backup 已成立且更新未提交，就优先恢复旧应用。
7. 第二次移动失败、最终校验失败、脚本异常退出或启动失败都触发恢复。若新版进程可能已经启动，先用同一 JXA 路径匹配法终止它；10 秒内不能确认退出时不移动其应用包，保留 target 与 backup 并给出人工恢复命令。否则移开失败副本并恢复 backup。恢复旧版成功且更新前它正在运行时，用 `/usr/bin/open` 加旧应用绝对路径重新启动；恢复失败时绝不删除 backup，并明确输出所有相关路径。
8. 仅当更新前该安装路径对应的进程正在运行时，才用 `/usr/bin/open` 加最终应用绝对路径重新启动；在 10 秒内用同一 JXA 路径匹配法确认运行实例出现，才视为启动成功。旧应用退出后、提交前发生的其他失败，也按上述规则恢复原路径与原运行状态。
9. 最终路径校验和必要的重启均成功后标记提交，再删除本次唯一 backup。脚本不删除其他历史版本、DMG、ZIP 或用户文件。
10. `/Applications` 不可写时，脚本只针对 sibling staging、重命名和清理操作使用 `sudo`；不以 root 身份下载、解析网络内容或执行下载包中的程序。

## 权限与兼容性

- Bundle ID 保持不变；若发布签名主体也保持一致，更新不主动重置屏幕录制或辅助功能权限。
- 若后续发布更换 `TeamIdentifier` 或 designated requirement，脚本应检测并中止，提示维护者先明确迁移策略；本次不自动执行 `tccutil reset`。
- 运行依赖仅使用 POSIX shell 内建能力、macOS 自带命令与框架，包括 `curl`、`ditto`、`zipinfo`、`shasum`、`codesign`、`lipo`、`osascript`/JXA + AppKit、`PlistBuddy` 及基础文件工具。外部命令使用系统绝对路径，不受调用者 `PATH` 注入影响。
- GitHub API 限流或网络失败时不修改现有应用，并给出可操作错误信息。可读取 `GITHUB_TOKEN` 作为可选请求令牌，但不打印令牌。

## 验收标准

- `/bin/sh -n scripts/update-snapclip.sh` 通过。
- 增加 `scripts/test-update-snapclip.sh`：在 `/tmp` 下使用本地 JSON 与 ZIP 文件夹具，不启动 HTTP 服务；覆盖已是最新版、发现新版、digest 不符、Bundle ID 不符、版本不符、签名或主体不符、并发锁、替换成功、移动失败、信号中断、启动失败与回滚。
- 测试用 API/资产地址和系统命令适配器只能在 `SNAPCLIP_TEST_MODE=1`、非 root、且目标解析后位于 `/tmp` 时启用；任一条件不满足都拒绝测试注入，生产流程不存在跳过校验的开关。事务测试用受控适配器注入 `codesign`/JXA 结果；另对真实已安装签名应用运行只读 smoke test，覆盖真实 Bundle、架构、`codesign`、TeamIdentifier 与 designated requirement 解析，但不替换应用。
- 每个测试断言退出码、关键输出、最终应用版本、backup/staging 状态及相关 PID；`--check` 和 `--dry-run` 还要断言没有应用替换、进程退出或启动副作用。
- 对真实 GitHub Release API 做一次只读检查，断言所选 tag 与资产符合上述规则并记录实际结果；不硬编码它必须是 Pre-release，也不在验收中替换 `/Applications/SnapClip.app`。
- `git diff --check` 通过。

## 明确不做

- 不集成 Sparkle，不修改 Swift/Xcode 工程。
- 不创建 LaunchAgent、cron 或登录项，不做定时静默更新。
- 不自动发布 Release，不修改版本号，不上传 GitHub。
- 不绕过摘要、Bundle ID、版本、架构或代码签名检查。

## 实现与验证状态（2026-09-09）

- 已交付 `scripts/update-snapclip.sh` 与 `scripts/test-update-snapclip.sh`，并在 README 中补充使用入口。
- `/bin/sh -n`、`git diff --check` 通过；11 个隔离场景全部通过，包括成功替换、摘要/Bundle/签名拒绝、并发锁、移动失败、启动失败、信号中断和回滚。
- 真实 GitHub API 能选中 `v1.4.1` Pre-release 的唯一 arm64 ZIP，资产元数据 SHA-256 为 `49dfe8694d0892f270e6f5fd87e6cc826640850eb1598464416e21dc9fd94f52`。
- 真实 ZIP 已在 `/tmp` 下载并验证：摘要、压缩包路径、无符号链接、Bundle ID、版本、arm64、代码签名结构、TeamIdentifier 与 designated requirement 均通过；临时文件已清理。复核时系统对当前 Apple Development 链返回过 `CSSMERR_TP_NOT_TRUSTED`，实现已按上述严格白名单区分信任链提示与内容损坏。
- 对 `/Applications/SnapClip.app` 运行真实 `--check`，正确报告本地与远端均为 `1.4.1`，没有替换或重启应用。
