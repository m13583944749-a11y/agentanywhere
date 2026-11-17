# GalNook iOS

以 GalNook 1.1.25 为基准实现的 iOS 16+ 原生 SwiftUI 客户端。工程包含完整源代码、资源、单元测试和未签名 IPA 的 macOS 构建流程。

## 功能

- 首页推荐、最近浏览、搜索、分页、排序、语言/平台/年份/评分/标签筛选
- NextMoe、VNDB、月幕、CnGal 数据解析；来源失败提示与本地历史
- 作品概览、多来源评分、关联作品、角色、外链、远程评论
- 收藏、游玩状态、个人评分、评论、头像、完整 JSON 备份与恢复
- 攻略 chart 文本渲染、评论原文/译文、离线路线导入、节点编辑、阅读与分享
- SearchGal 表单 POST + SSE 事件解析、资源去重和兼容筛选
- 直链下载、断点续传、暂停/恢复、重试、任务持久化与完成文件分享
- 夸克/UC、百度、115、123、蓝奏解析；Cookie/Token 使用 iOS 钥匙串
- ZIP、7z、LZ4 安全解压；防止路径穿越和符号链接攻击
- 本地游戏库、引擎识别、启动文件编辑、完整目录或 ZIP 分享至咔咔喵

## 构建要求

- macOS 15+
- Xcode 16.4
- XcodeGen
- iOS/iPadOS 16.0 或更高版本

```bash
brew install xcodegen
make generate
make test
make build
```

构建结果：

```text
.build/GalNook.xcarchive
.build/GalNook.ipa
```

可覆盖 Bundle ID：

```bash
make build BUNDLE_ID=com.example.galnook
```

`GalNook.ipa` 是未签名包，安装前需使用自己的开发证书重签名。若只需要日常安装，直接用 Xcode 打开生成的 `GalNook.xcodeproj`，选择自己的 Team 和真机运行最方便。

## GitHub Actions

`.github/workflows/ios.yml` 在 `macos-15` 上执行：

1. 生成 Xcode 工程
2. 在 iPhone 模拟器运行测试
3. 构建 generic iOS 未签名 xcarchive
4. 打包并上传未签名 IPA

仓库变量 `GALNOOK_BUNDLE_ID` 可覆盖默认 Bundle ID。

## 主要目录

```text
ios/GalNook/App                 应用入口与主导航
ios/GalNook/Core/Networking     数据源与 SearchGal
ios/GalNook/Core/Pan            网盘解析与钥匙串账号
ios/GalNook/Core/Downloads      下载、续传与分片引擎
ios/GalNook/Core/Archives       安全解压
ios/GalNook/Core/Library        游戏导入、检测与分享
ios/GalNook/Core/Routes         离线路线存储
ios/GalNook/Core/Records        个人资料、记录和评论
ios/GalNook/Features            各功能页面
ios/GalNookTests                XCTest
research                        原 APK 功能与 API 逆向证据
```

## 平台边界

- Android 的 GalBuilt 安装与启动在 iOS 上替换为内置游戏库和系统文件分享；游戏实际运行由咔咔喵等播放器完成。
- Android 跨应用悬浮攻略不能原样移植。工程提供的是应用内浮层，不宣称可悬浮在其他 iOS App 上。
- SWCompression 4.8.6 用于兼容 iOS 16。ZIP/7z/LZ4 可解压；RAR 保留原包分享，并可通过 `ArchiveBackend` 注册独立 RAR 后端。
- 迅雷、139、光年在原 APK 中没有内置直链实现，因此保留网页入口，不伪造解析结果。
- 网盘接口没有使用有效私人分享和 Cookie 做成功断言；账号相关行为需要在自己的账号与资源上复测。

## 验证记录

- 85 个 Swift 文件通过 tree-sitter 语法解析，XcodeGen 2.47.0 已实际生成 `GalNook.xcodeproj`。
- 整合核心模块通过 Swift 6.0.3 类型检查与构建。
- 全部 **72 项可移植 XCTest 通过，0 失败**：Archive 12、Download 6、Segmented 6、Library 12、Networking 4、Pan 17、Profile 8、Routes 7。
- 测试使用 Linux 的 Combine/Security/URLSession 兼容垫片；临时 SWCompression 源码增加 CP437→UTF-8 回退以规避 Swift 6 corelibs 差异，生产依赖仍为上游 4.8.6。
- 当前 Linux 环境未执行 Xcode 模拟器或真机构建；IPA 以 CI/本机 macOS 的实际构建结果为准。详见 `research/validation.md`。

原项目许可与版权说明见 `LICENSE`、`NOTICE.md`。
