# Agent Note: 在检测到 CIFS/SMB 挂载时跳过 chmod

Status: implemented

[English](2026-08-28-cifs-chmod-skip.md) | 中文

## 问题

`@deepseek-ai/dsh-fs-local` 中的 `writeFileAtomic` 通过显式 `chmod` 调用保护正在写入的内容：`mkdir` 之后把暂存目录 chmod 为 `0o700`，`open` 之后把临时文件 chmod 为 `0o600`，最后再把现有目标的 mode 重新应用到已发布的文件上。在 CIFS/SMB 挂载上，这些调用通常会以 `EPERM`/`EOPNOTSUPP` 失败：SMB 没有可设置的 POSIX 权限位模型——访问控制存在于服务器端的共享 ACL 中——因此 CIFS 文件系统驱动转发的客户端 `chmod` 系统调用无事可做。由于这些调用没有防护，失败会沿着整个 `writeFileAtomic` 调用传播，导致 `write`/`edit` 工具彻底失败，即便实际的内容写入（`open`/`writeFile`/`rename`）原本会成功。

这与 Windows 的情况不同（参见已归档的[Windows fs permissions Agent Note](../architecture/2026-07-05-windows-fs-permissions.md)）：在 Windows 上，`chmod` 是一个良性空操作（它只会切换只读属性，而本包传入的每个 mode 都带有 owner-write），因此调用它没有代价，那篇笔记也明确否决了为其添加跳过分支。CIFS 则会主动抛出异常而非静默空操作，这正是本处需要加防护、而彼处被否决的原因。

## 决策

`writeFileAtomic` 通过 `fs.promises.statfs` 对目标目录所在文件系统每次调用探测一次，当报告的类型为 `CIFS_SUPER_MAGIC`（`0xff534d42`，Linux 的 `cifs.ko` 为 `cifs` 与 `smb3` 挂载共同报告的魔数）时，跳过全部三次 `chmod` 调用。该探测在 Windows 上直接短路为 `false`（照常尝试 chmod，行为不变）——Windows 自身的空操作路径已经覆盖了该平台，因此这一 CIFS 专属探测只针对 POSIX；在任何 `statfs` 失败或非 CIFS 结果时同样短路为 `false`，确保无法判定的文件系统绝不会被静默降级处理。

跳过时，暂存目录与临时文件保留 `mkdir`/`open` 在创建时产生的 mode（取决于进程 umask，在 CIFS 上还取决于服务器自身的 mode 映射），现有目标的 mode 也不会被重新应用到已发布的文件上。该探测可通过 `FsIoInternals.isChmodUnsupported` 覆盖，沿用本文件既有的测试接缝模式（`internals.platform`、`internals.copyFileDacl` 等），因为 CI 中无法获得真实的 CIFS 挂载。

## 考虑过的替代方案

**无论文件系统类型，捕获并吞掉每次 `chmod` 调用的 `EPERM`/`EOPNOTSUPP`。** 已否决：这也会掩盖普通 POSIX 文件系统上的真实权限错误，而在那种情况下，同样的 errno 表示一个值得大声报出的真实故障。正向的文件系统类型检查能把跳过范围限定在这一种失败属于预期且无害的文件系统类别上。

**在 Windows 上以同样方式跳过 chmod。** 已被本决策所扩展的架构笔记否决：Windows 上的 chmod 是良性空操作，为其加防护只会增加分支而不改变行为。CIFS 的情况不同，因为该调用会主动抛出异常。

**被动地检测"chmod 不受支持"，即尝试调用后检查错误。** 已否决，转而采用主动的 `statfs` 探测：被动检测需要三个调用点各自携带相同 errno 允许列表的 try/catch，会把本应只需确立一次的同一项文件系统事实的特殊处理重复三倍。

## 后果

对 CIFS/SMB 支持的目标（例如网络共享挂载的工作区）的写入现在会成功，而不是在第一次 `chmod` 处失败。代价是：在这样的挂载上，替换操作不再跨越保留现有文件的 mode，新文件获得的是 `open()` 创建时参数在该处产生的 mode，而非保证的 `0o600`——这是可以接受的，因为在这种情况下，SMB 自身的服务器端 ACL 才是实际的访问控制机制，而不是本包原本会主张的客户端 POSIX 位。`fsio.ts` 中 `info.type === CIFS_SUPER_MAGIC` 的真分支与 `statfs` 失败的 catch 分支都标注了 `v8 ignore`，因为二者都无法在没有真实 CIFS 挂载或 CI 中真实 `statfs` 故障的情况下触达；这些分支驱动的 `skipChmod` *行为*则通过 `fsio.spec.ts` 中的 `internals.isChmodUnsupported` 测试接缝覆盖来验证。
