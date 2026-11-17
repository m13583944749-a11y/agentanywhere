# 验证记录

验证时间：2026-11-18（Asia/Shanghai）。

## 已执行并通过

1. **XcodeGen 2.47.0**
   - 从标签 `2.47.0` 源码构建 Linux 可执行文件。
   - 已实际生成 `GalNook.xcodeproj/project.pbxproj` 与共享 scheme。
   - 工程包含应用图标、85 个 Swift 源码/测试文件和 SWCompression 4.8.6。

2. **Swift 语法与 YAML**
   - 85 个 Swift 文件，tree-sitter `ERROR`/缺失节点均为 0。
   - `project.yml` 解析通过。

3. **核心模块真实编译**
   - 工具链：Swift 6.0.3，aarch64-unknown-linux-gnu。
   - 整合 Models、Networking、Downloads、Archives、Library、Pan、Records、Routes 后构建成功。
   - 非 Apple 平台仅在临时验证目录使用 Combine、Security、URLSession 兼容垫片，不修改生产代码来绕过 Apple API。

4. **全部 72 项可移植 XCTest**
   - `Executed 72 tests, with 0 failures (0 unexpected) in 8.237 seconds`。

   | 套件 | 数量 | 结果 |
   |---|---:|---|
   | ArchiveTests | 12 | 全部通过 |
   | DownloadTests | 6 | 全部通过 |
   | LibraryTests | 12 | 全部通过 |
   | NetworkingTests | 4 | 全部通过 |
   | PanTests | 17 | 全部通过 |
   | ProfileTests | 8 | 全部通过 |
   | RoutesTests | 7 | 全部通过 |
   | SegmentedDownloadTests | 6 | 全部通过 |

   最终日志：`research/test-results.txt`。

5. **公开接口实际请求**
   - NextMoe 作品列表、扩展字段、游标与详情样例已验证。
   - VNDB 搜索及空筛选榜单返回 HTTP 200。
   - CnGal 索引与详情结构已验证。
   - SearchGal SSE 请求/解析已验证；另有离线 XCTest。
   - 网盘没有使用私人分享或有效 Cookie 做在线成功断言；17 项网盘测试均为 URLProtocol 离线用例。

## 验证中发现并修复

- TaskGroup 的 `try await`、nil 合并与比较优先级、长表达式类型检查问题。
- 离线路线存储 Combine 导入和不依赖 SwiftUI 的节点排序。
- `FileManager.replaceItemAt` 在 corelibs 第二次写入时报错，统一改用 Foundation `.atomic`。
- 分片预分配文件的逻辑进度读取，取消后分段续传与字节一致性。
- Ren'Py 已识别目录与未识别容器的根目录回退。
- Swift 6 corelibs 的 CP437 解码差异：仅验证用 SWCompression 源码增加 UTF-8 回退；生产仍使用上游 4.8.6。
- Linux URLSession 测试桥在取消/完成竞争下的重复 continuation 恢复，已加锁修复；生产使用 Apple `URLSession.bytes(for:)`。

## 未执行

- 当前环境是 Ubuntu/aarch64，没有 Apple SDK、Xcode 或 iOS 模拟器，因此未执行 SwiftUI 的 Apple SDK 编译、模拟器测试、真机安装和 archive。
- `.github/workflows/ios.yml` 已在 macOS 15 / Xcode 16.4 上配置完整测试、未签名 xcarchive 和 IPA 打包；交付 IPA 应由该 CI 或 macOS 本机实际生成。
- 未签名 IPA 安装前需要用户自己的签名。
