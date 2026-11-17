# GalNook 1.1.25 Android 功能逆向清单（供 iOS 复刻）

- 分析对象：`/root/.dsh/attachments/v1/files/80/80d61fbf4736fc5b42b043974b8f0a597ecd1283916b686f4a3545b7aa16c5f5/GalNook.apk`
- 版本证据：界面为 **1.1.25**，关于页复制文本为 `GalNook 1.1.25 (72)`，`minSdk 29 / targetSdk 36`。证据：`z4/o1.smali:87-107`、`z4/k0.smali:1078-1082`。
- 本文证据路径均相对：`/root/workspace/galnook-analysis/smali/smali/`。行号是该 smali 文件的真实行号；中文 `const-string` 已按 Unicode 转义解码。
- 只做了静态分析，没有运行 APK。下文“代码确认”均可由所列指令复核；“未发现”只表示此 DEX 中未找到写入/注册路径，不把它说成界面宣称。

## 1. 最重要的复刻结论

1. **GalNook 是 Jetpack Compose 单 Activity 应用，底部四项为首页、作品、攻略、我的。** 共注册 18 个 Composable 路由（含参数路由）。证据：`com/galnook/MainActivity.smali:145-210`、`i4/q.smali:121-477`、`t4/u.smali:213-230,479-484,635-650`。
2. **本地游戏扫描、引擎识别、游玩时长已不在 GalNook 内，而是独立应用 GalBuilt。** GalNook 只保留入口、启动检测和下载安装引导，不能把旧 `local_columns` 设置误解为仍有完整本地模式。证据：`z4/e.smali:183-241`、`z4/k0.smali:988-992`。
3. **首页“最近游玩”实际是最近浏览作品详情。** 它来自 `recent.viewed_at`，最多显示 5 部，不是启动游戏或累计时长。证据：`t4/t.smali:470-486`、`k4/c.smali:850-890`、`v4/l.smali:1555-1594`、`b0/p.smali:1515-1519`。
4. **普通下载是应用自实现下载器，不是系统 DownloadManager。** 支持任务持久化、暂停/继续、断点续传、可选 8 分片、进度/速度/剩余时间、打开文件、删除任务。应用更新另支持系统下载。证据：`v4/j.smali:68-127,700-888,1639-1810`、`r/d.smali:679-723,908-1047`、`z4/i2.smali:613-639`。
5. **收藏模型与 UI 存在，但此 DEX 中未找到独立收藏写入路径。** 数据库有 `records.favorite`，个人页也统计它，但唯一 `records` 写入点只更新游玩状态并原样保留 favorite/score。iOS 不应仅凭空状态文案推断 Android 收藏按钮已完整落地，建议把“独立收藏开关”列为需补齐/复核项。证据：`v4/l.smali:1870-1878`、`o/f0.smali:481-565`、`t4/t.smali:409-441`。
6. **“导入作品记录”实际只导入作品元数据。** JSON 数组接受 `id/workId`、`title/name`、`titleZh`、`company`、`releaseDate`、`coverUrl`，随后仅写 `works` 缓存；没有导入 favorite/state/score/recent/reviews。证据：`z4/v1.smali:172-438`。
7. **数据源/错误处理做得较细。** 有主源失败切次源提示、HTTP 404 专门说明、WebView 主框架错误、下载分片错误、网盘登录/提取码/风控错误、可复制错误报告和上次崩溃报告。证据：`y4/c.smali:272-340`、`k4/c.smali:877-919`、`z4/s.smali:134-226`、`v4/j.smali:767-808,971-1049`、`b0/f.smali:944-1049`。

## 2. 全部 Composable 路由与页面映射

| 路由 | 实际 Composable / 页面 | 可执行功能与证据 |
|---|---|---|
| `home` | `z4/y.j` 首页 | 编辑推荐、最近浏览、本周热门、高分作品、下拉刷新、打开作品、下载中心。注册：`i4/q.smali:125-155`；入口参数：`z4/y.smali:5497-5512`；内容：`b0/p.smali:1457-1519,1637-1639,1737-1739`。 |
| `works` | `z4/r2.c` 作品库 | 搜索、排序、语言/平台/年份/评分/标签筛选、网格列表、打开作品。注册：`i4/q.smali:157-173`；搜索列表：`z4/q2.smali:298-481,600-733`。 |
| `routes` | `z4/y.t` 攻略总览（无 workId） | 显示已导入/自建路线；空态引导从作品详情导入。注册：`i4/q.smali:175-191`、`b3/c.smali:63-72`；空态：`z4/k.smali:342-360`。 |
| `profile` | `z4/b2.c` 我的 | 头像、显示名、收藏/已玩/评论计数、状态标签、作品记录、设置、记录导入。注册：`i4/q.smali:193-209`；实现：`z4/b2.smali:519-751,1268-1374`。 |
| `settings` | `z4/y.w` 设置首页 | 外观、内容、数据源、通用、本地模式、网盘解析、权限、关于。注册：`i4/q.smali:211-237`；入口：`z4/k0.smali:855-1082`。 |
| `settings/appearance` | `z4/y.c` 外观 | 动态色、内置色、深浅色、预测性返回、隐藏状态栏、优先加载。注册：`i4/q.smali:239-255`；控件：`z4/h2.smali:245-247,1070-1183,1257-1419,1517-1547`。 |
| `settings/content` | `z4/y.f` 内容 | R18 开关及确认、显示名。注册：`i4/q.smali:257-273`；文案：`z4/b0.smali:743-819,895-977`。 |
| `settings/sources` | `z4/y.x` 数据源 | SearchGal 地址、月幕 client_id 并保存。注册：`i4/q.smali:275-291`；两个输入框及保存：`a0/f0.smali:181-518`、`o/f0.smali:73-145,262-407`。 |
| `settings/general` | `z4/y.h` 通用 | SearchGal 限定、应用内访问、自动更新、测速重试、多线程。注册：`i4/q.smali:293-309`；控件：`z4/h2.smali:1667-1815,1841-1961`、`z4/c.smali:1230-1366`。 |
| `settings/pan` | `z4/y.n` 网盘解析 | 识别开关、账号入口、支持站点、下载器说明。注册：`i4/q.smali:311-327`；页面：`z4/y0.smali:247-377,495-650,869-884,1023-1051`。 |
| `settings/pan/accounts` | `z4/y.l` 网盘账号 | 各站点登录/退出。注册：`i4/q.smali:329-345`；回调：`z4/y.smali:6482-6598`。 |
| `settings/pan/login/{siteId}` | `z4/y.m` 站点登录 WebView | 按 siteId 找站点与登录 URL，保存 Cookie/令牌或返回。注册：`i4/q.smali:347-363`、`t4/n.smali:55-141`；页面：`z4/y.smali:6624-6899`。 |
| `settings/permissions` | `z4/y.q` 权限 | 应用列表、通知、悬浮窗、网络、下载目录状态与授权入口。注册：`i4/q.smali:365-381`；控件：`z4/q1.smali:320-326,394-398,468-470,509-562`。 |
| `settings/about` | `z4/y.a` 关于 | 版本、检查更新、赞助、QQ 群、复制版本信息。注册：`i4/q.smali:383-399`；实现：`z4/y.smali:2822-3136`、`z4/a0.smali:560-590,843-901,1184-1242`。 |
| `downloads` | `z4/y.g` 下载中心 | 任务进度、暂停/继续/打开/移除、清除已完成。注册：`i4/q.smali:401-417`；空态：`z4/k0.smali:2017-2125`；按钮：`z4/z.smali:655-750,845-1035`。 |
| `detail/{id}` | `z4/x0.b` 作品详情 | 概览、评论、角色、关联、攻略、记录、下载/打开、资源聚合。注册：`i4/q.smali:419-441`；参数：`t4/p.smali:65-112`；页签：`z4/x0.smali:16-34`。 |
| `tag/{tagId}/{tagName}` | `z4/y.A` 标签结果 | 标签作品列表、加载/错误/空态、总数、进入详情。注册：`i4/q.smali:443-459`；参数与调用：`t4/m.smali:97-224`；状态：`z4/c.smali:451-515,672-727`。 |
| `routes/{workId}` | `z4/y.t` 指定作品攻略 | NextMoe 攻略、角色线、导入、编辑、悬浮查看。注册：`i4/q.smali:461-477`；参数：`t4/o.smali:430-500`；功能：`z4/i.smali:287-461`、`z4/k.smali:354-358,549-590`。 |

底部导航切换使用当前目的地做 pop-up、单次顶部恢复等逻辑，详情路由拼接为 `detail/` + id，攻略为 `routes/` + workId，网盘登录为 `settings/pan/login/` + siteId。证据：`t4/j.smali:51-89,91-147`；设置项跳转：`z4/j2.smali:37-100`。

## 3. 页面与交互功能清单

### 3.1 首页 `home`

- [ ] **编辑推荐**：来自 NextMoe 多源对齐目录，取前 6 部并可点进详情。证据：`b0/p.smali:1457-1477`。
- [ ] **最近浏览**：展示最近查看详情的作品，UI 取最近 5 个；点击再次进入详情。证据：SQL `ORDER BY r.viewed_at DESC LIMIT 5` 在 `t4/t.smali:470-486`，UI 在 `b0/p.smali:1515-1597`。
- [ ] **本周热门**：按 NextMoe 热度/站内评分语义排列；证据：`b0/p.smali:1637-1703`。
- [ ] **高分作品**：按 VNDB 评分，UI 标为 100 分制；证据：`b0/p.smali:1737-1803`。
- [ ] **刷新与错误/空态**：支持下拉刷新；无数据时提示可下拉或去作品页搜索。证据：`b0/p.smali:1819-1861`。
- [ ] **下载入口**：首页顶栏可进入 `downloads`。证据：`z4/y.smali:5506-5512,5604-5628`。

### 3.2 作品库 `works` 与标签页

- [ ] **搜索**：标题输入即更新查询，支持键盘搜索；无结果时提示换关键词或清筛选。证据：`z4/q2.smali:298-481,600-658`。
- [ ] **排序**：全部、热度、NextMoe 评分、VNDB 评分、批评空间评分。证据：`z4/r2.smali:18-66`。
- [ ] **语言**：日语、简中、繁中、英语、韩语。证据：`z4/r2.smali:68-116`。
- [ ] **平台**：Windows、Android、iOS、PS Vita、PS4、Switch。证据：`z4/r2.smali:118-174`。
- [ ] **年份**：2026 至 2020 的快捷选项（smali 整数 `0x7ea`–`0x7e4`）；评分下限为 8/7/6；标签取前 30 个并可筛选。证据：`z4/r2.smali:1459-1652,1678-1857,1883-2048`。
- [ ] **筛选面板与重置**：筛选以底部面板呈现，另有重置按钮；筛选状态由 `x4/d0` 管理。证据：`z4/r2.smali:715-1189`、`z4/a0.smali:79-115`。
- [ ] **标签页**：显示获取中、错误、无作品和总数，点击作品仍进入 `detail/{id}`。证据：`z4/c.smali:451-515,672-727`。

### 3.3 作品详情 `detail/{id}`

- [ ] **五个页签**：概览、评论、角色、关联、攻略，顺序固定在静态列表。证据：`z4/x0.smali:16-34`；页签 UI：`z4/g0.smali:177-420`。
- [ ] **概览**：封面、标题/中文名、会社、发售日、标签、来源及多源评分、简介；无简介时显示专门空态。证据：`z4/m0.smali:909-1109,1370`、`y4/h.smali:2348`、`y4/c.smali:218-340`。
- [ ] **评论**：NextMoe 评论列表，支持中文译文/原文点击切换、展开/折叠；VNDB 与批评空间另有入口。证据：`z4/l0.smali:221-238,409-417,1091-1099`、`z4/k0.smali:2613-2830`、`z4/z.smali:1890-1985`。
- [ ] **角色**：角色列表、所属作品、CV、简介；无角色/无简介有独立空态。证据：`z4/m0.smali:109-216`、`t4/c.smali:952-1087`、`f0/o.smali:332-400`。
- [ ] **关联**：续作、动画化/改编、外传、同世界观、不同演绎、角色出演、其他关联；标签仍可继续跳转。证据：`b0/p.smali:2194-2353,2545,3246`。
- [ ] **个人记录**：可选未标记/在玩/已玩/弃坑并显示我的评分。状态枚举及中文：`u4/i.smali:32-86`；设置对话框：`z4/k0.smali:568,2297-2392`；写入：`o/f0.smali:481-565`。
- [ ] **安装检测**：枚举已安装应用，标题规范化相似度至少 0.6，排除 `no_<package>` 标记；确认后写 `ok_<package>=workTitle`，下载按钮变打开；否定写 `no_<package>=true`，启动失败 Toast。证据：`v4/o.smali:39-67,94-165`、`f0/o.smali:507-573`、`b0/f.smali:782-889,614-705`。
- [ ] **资源聚合**：从 SearchGal 获取免登录直链，首次查询 UI 预计 15–30 秒；没有结果时给替代提示；支持测速、重测、打开最快链接。证据：`t0/t.smali:106-198,362-454`、`z4/k0.smali:3600-3889`。
- [ ] **下载/打开链接**：可应用内下载，或弹窗选择系统浏览器/应用内浏览器；设置后可默认应用内。证据：`z4/x.smali:2936-3176`、`z4/w.smali:255-286`、`z4/h2.smali:1755-1757`。
- [ ] **攻略入口**：从详情进入 `routes/{workId}`，可预览角色线。证据：`t4/j.smali:134-147`、`z4/x.smali:3296-3374`。

### 3.4 攻略 `routes` 与 `routes/{workId}`

- [ ] **远程角色线**：读取 NextMoe walkthrough，列出角色；进入后查看结局、选项段和达成条件。证据：`z4/i.smali:418-461`、`f0/n.smali:999-1060,1683`。
- [ ] **导入**：可全部导入或勾选角色后导入，结果写入本地 `routes` 与 `route_nodes`，离线可看；成功 Toast 指出去攻略页查看。证据：`z4/w.smali:876-884,1517-1537`、`f0/w.smali:1375-1377`；表结构：`v4/l.smali:1882-1888`。
- [ ] **本地总览**：无路线时引导从详情导入；指定作品无远程攻略时区分“请求失败”“R18 被过滤”“接口正常但未收录”。证据：`z4/k.smali:342-360,549-590`。
- [ ] **自建/编辑**：新增路线节点、节点名称（如结局 A）、添加结局/选项/注意事项、条件、其他选项、备注、删除节点、删除整条攻略、重新导入。证据：`z4/b0.smali:1402-1478,1568-1678,1912-2018`、`b0/p.smali:404-425,522-714`。
- [ ] **节点存储**：节点含 label、kind、condition、order_index、notes、step_type、alternatives；替代项用单元分隔符持久化；删除路线先删节点再删路线。证据：`v4/l.smali:1513-1550,1597-1822,1886-1888`。
- [ ] **悬浮攻略**：需要“显示在其他应用上层”权限；以常驻通知和系统 WindowManager 显示标题/正文，可关闭、拖动、长按一角缩放。证据：`z4/b0.smali:1754-1830`、`com/galnook/service/RouteOverlayService.smali:166-197,233-289,559-681`、`w4/b.smali:117-236,257-275`。缩放范围：宽 180–480dp、高 140–720dp，见 `w4/b.smali:187-229`。

### 3.5 我的 `profile`

- [ ] **头像与显示名**：系统图片选择后复制到 `filesDir/avatar/avatar_<timestamp>.jpg`，路径写 `avatar_path`；显示名去首尾空格，最多 24 字，空白恢复“本地用户”。证据：`z4/v1.smali:487-531,641-684,846-868`、`z4/x.smali:1316-1468`、`x4/t.smali:1296-1369`。
- [ ] **计数**：分别执行 favorite=1、state='played'、reviews 总数查询，显示“收藏 N · 已玩 N · 评论 N”。证据：`t4/t.smali:399-441`、`z4/x1.smali:746-798`。
- [ ] **状态标签与列表**：已玩、在玩、弃坑；记录按更新时间倒序最多 200，点击进详情；空态提示收藏或设置状态。证据：`z4/b2.smali:14-34`、`k4/c.smali:259-371`、`z4/z1.smali:364-390`。
- [ ] **导入记录**：通过系统文档选择器读 JSON 数组并刷新个人页。仅导入上述作品元数据，不是完整备份；未发现导出功能。证据：`z4/b2.smali:1268-1346`、`z4/v1.smali:65-180,224-372,420-479`。
- [ ] **收藏/评论实现边界**：有表、计数和“已收藏”卡片标记，但未找到独立 favorite 写入口；`reviews` 也只有读取/计数路径，未找到本地新增评论写入口。证据：`z4/j1.smali:496-516`、`k4/c.smali:3837-4006`、`o/f0.smali:481-565`。复刻时应把它列为明确核对项，而不是宣称 Android 已能完整新增收藏/评论。

### 3.6 应用内浏览器与网盘解析

- [ ] **浏览器选择**：链接可系统浏览器或应用内 WebView；默认弹窗询问，`open_in_app=true` 后直接应用内。证据：`z4/x.smali:3014-3092`、`z4/h2.smali:1755-1757`。
- [ ] **WebView 兼容处理**：注入 dvh/svh/lvh 回退和 dialog transform 修正脚本；主框架网络/HTTP 错误显示“加载失败”或状态码。证据：`z4/s.smali:79-86,134-226`。
- [ ] **旧 WebView 空页提示**：提示单页应用可能因系统 WebView 太旧空白，传统页面仍可显示。证据：`z4/i.smali:1277-1365`。
- [ ] **链接识别**：`pan_parse=true` 时，点受支持网盘分享链接先弹窗说明，再选择解析；文件页有取直链中、无结果、需登录、解析失败状态。证据：`f0/o.smali:104-156`、`z4/m1.smali:901-1003,1305-1432`。
- [ ] **文件操作**：成功结果含来源、文件数和文件列表，可直接下载或复制直链；失败可复制错误，需登录可跳账号页。证据：`z4/m1.smali:1040-1273`、`z4/o1.smali:237-280`、`z4/a0.smali:3270-3460`。
- [ ] **支持站点**：蓝奏云、蓝奏云优享版、123 云盘、夸克、UC、百度、115、迅雷、139；域名和“是否免登录”标志在静态表。证据：`v4/v.smali:26-222`。夸克/UC 仍有游客限制等错误分支，不能实现成永远免登录，相关错误：`v4/v.smali:3793-3826`。
- [ ] **账号登录**：登录页按桌面端访问；保存 Cookie 与本地令牌，不保存账号密码，退出清除。123 云盘额外执行 `localStorage.authorToken` 读取并写 `.token`。证据：`z4/y0.smali:287-377`、`g1/b.smali:150-223`、`z4/l1.smali:118`。
- [ ] **账号存储**：应用启动创建 `galnook.pan_accounts` SharedPreferences；登录状态按站点 Cookie 判断，夸克/UC 还检查 `__pus/__puus`，123 检查 token。证据：`com/galnook/GalNookApp.smali:32-57`、`v4/s.smali:211-240,242-375`。

## 4. 设置项、默认值与持久化（逐项）

设置使用 `galnook.settings`；另有 `galnook.cache`、`galnook.installed`、`galnook.pan_accounts`、`galnook.downloads.v2`。证据：`v4/q.smali:11-43`、`v4/o.smali:17-32`、`v4/j.smali:68-74`。

| 设置 | Android 默认值/选项 | 行为与证据 |
|---|---|---|
| `hide_status_bar` | `true` | 隐藏状态栏/沉浸顶栏，下滑可临时呼出。读取：`x4/t.smali:332-340`；写入：`z4/p1.smali:815-844`；说明：`z4/h2.smali:1335-1343`。 |
| `dynamic_color` | `true` | Android 12+ 莫奈动态色；关闭用内置色。读取：`x4/t.smali:342-346`；写入：`x4/t.smali:3414-3437`；说明：`z4/h2.smali:245-247`。 |
| `palette_index` | `0` | 内置配色索引；配色名包括稻荷、紫缘、Galgamex、真红、鲲。读取：`x4/t.smali:348-354`；写入：`z4/p2.smali:69`；名单：`z4/x0.smali:36-54`。 |
| `dark_mode` | `system` | system / dark / light；手动深色会关闭跟随系统。读取：`x4/t.smali:380-396`；写入：`x4/t.smali:3316-3341`、`z4/p1.smali:1117-1143`；说明：`z4/h2.smali:1070-1137`。 |
| `predictive_back` | `true` | Android 13+ 系统预测性返回，关闭由应用处理。读取：`x4/t.smali:374-378`；写入：`z4/p1.smali:966-995`；说明：`z4/h2.smali:1175-1183`。 |
| `last_mode` | `home` | 保存最后主页面。读取：`x4/t.smali:356-372`。 |
| `load_priority` | `mix` | mix / nextmoe / vndb；非法值回退 mix，影响全部列表前 16 行来源优先。读取：`x4/t.smali:492-508`；写入：`z4/f0.smali:149-208`；说明：`z4/h2.smali:1361-1419,1517-1547`。 |
| `nsfw` | `false` | 过滤 R18 作品、封面和攻略；开启影响 repository。读取：`x4/t.smali:398-402`；写入：`x4/t.smali:858-885`。 |
| `user_name` | `本地用户` | 本地显示名，空白恢复默认。读取：`x4/t.smali:454-470`；写入：`x4/t.smali:1296-1369`。 |
| `avatar_path` | 空 | 头像绝对路径。读取：`x4/t.smali:719-729`；写入：`z4/v1.smali:666-684`。 |
| `searchgal_base` | `https://vercel.api.searchgal.top` | SearchGal 实例地址，保存空值恢复默认并立即更新 repository。读取：`x4/t.smali:638-654`；写入：`o/f0.smali:262-322`；输入框：`z4/b0.smali:591`。 |
| `ymgal_id` | 空 | 月幕 client_id，留空用公共凭证。读取：`x4/t.smali:422-436`；保存：`o/f0.smali:89-125`；说明：`z4/b0.smali:667`。 |
| `ymgal_secret` | 空 | 初始化可读，但当前“保存数据源”明确将其重置为空串，未发现独立 secret 输入框。读取：`x4/t.smali:438-452`；清空：`o/f0.smali:127-145`。 |
| `only_searchgal` | `true` | 下载只查设置的 SearchGal 实例，不用内置线路补缺。读取：`x4/t.smali:510-514`；写入：`z4/p1.smali:664-693`；说明：`z4/h2.smali:1703-1711`。 |
| `open_in_app` | `false` | 下载链接默认应用内打开，不再询问。读取：`x4/t.smali:516-520`；写入：`z4/p1.smali:513-542`。 |
| `auto_check_update` | `true` | 每次进入应用检查一次，关闭只能关于页手动。读取：`x4/t.smali:522-526`；写入：`z4/p1.smali:362-391`；说明：`z4/h2.smali:1807-1815`。 |
| `download_retry` | `false` | 线路检测失败再检测，达到次数才不可用。读取：`x4/t.smali:472-476`；写入：`z4/p1.smali:209-238`；说明：`z4/h2.smali:1915-1923`。 |
| `download_retry_count` | `2`，实际夹到 1–5 | 开启时尝试次数为设定值 + 1（含首次）；关闭只一次。读取：`x4/t.smali:478-484`、`f0/z0.smali:758-791`。 |
| `multi_thread_download` | `false` | 开启后支持 Range 的直链按 8 分片，暂停继续不受影响。读取：`x4/t.smali:534-538`；写入：`z4/p1.smali:56-83`；说明：`z4/c.smali:1308-1310`。 |
| `pan_parse` | `true` | 应用内识别网盘分享并询问解析。读取：`x4/t.smali:528-532`；写入：`z4/p1.smali:1167-1196`；说明：`z4/y0.smali:247-259`。 |
| `local_columns` | `0` | 仍被读取，但本地模式已拆 GalBuilt；未发现对应本地页面。读取：`x4/t.smali:486-490`；拆分：`z4/e.smali:183`。 |
| `disclaimer_accepted` | `false` | 首次免责声明状态；同意写 true。读取：`f0/o.smali:2898-2918`；写入：`t4/b.smali:125-144`。 |
| `skipped_update_version` | 空 | 跳过指定版本。写入：`z4/e0.smali:165`；按钮：`z4/z.smali:370`。 |
| `ok_<package>` / `no_<package>` | 无 | 保存安装匹配确认/排除。写入：`b0/f.smali:804-822`、`x4/t.smali:2077-2110`；匹配：`v4/o.smali:147-163`。 |
| `sg_<workId>` | 无 | SearchGal 查询结果缓存到 `galnook.cache`。实现：`v4/q.smali:55-88,399`。 |

**仅内部出现、不要误当成可见设置项：** `api_base`、`api_base_host`、`pan_api_base`、`pan_api_key` 在 ViewModel 初始化中读取，但已分析的数据源/网盘设置页没有对应可见编辑控件。证据：`x4/t.smali:404-420,540-584,656-690`；可见数据源页只有 `x4/a0.n` 与 `.p` 两个输入状态：`z4/y.smali:10382-10468`。

## 5. 下载中心与文件系统（重点实现规格）

### 5.1 任务创建与命名

- 新建任务输入为 `title, url, referer`；任务 id 为 `System.currentTimeMillis()`，并读取 `multi_thread_download` 决定后续是否 8 分片。证据：`x4/t.smali:2320-2416`。
- 首选目录：`getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)`，即应用专属外部 Download；为 null 时回退 `filesDir/downloads`。证据：`v4/j.smali:106-127`。典型外部路径为 `Android/data/com.galnook/files/Download/`，权限页也明确无需存储授权、卸载删除：`z4/q1.smali:550-562`。
- 文件名直接来自 title，不从 URL 推断扩展名：将 `\ / : * ? " < > |` 全替换为 `_`，取前 60 字符；空白则 `galnook-download`。证据：`v4/j.smali:2450-2495`。
- 重名时依次生成 `name (1).ext`、`name (2).ext`；有点扩展名时编号插入扩展名前。证据：`v4/j.smali:2500-2586`。
- 任务以 id 为 key 写 `galnook.downloads.v2` JSON：`title,url,referer,path,total,done,status,rangeOk,multiThread,segs[{s,e,d}]`。启动按 id 排序恢复，原“下载中”状态转为“暂停”并自动尝试继续。证据：`v4/j.smali:129-198,220-515,1639-1810`。

### 5.2 状态、分片与续传

- 状态码在 UI 中映射为：0 连接中、1 下载中、2 已暂停、3 已完成、4 下载失败；列表显示百分比、已下/总大小、分片数或单线程、速度和预计剩余秒数。证据：`r/d.smali:679-723,908-1047`。
- 先用 `Range: bytes=0-0` 探测；206 时从 `Content-Range` 取总大小并确认 Range，200 时用 `Content-Length`；取不到大小即失败。证据：`v4/j.smali:1136-1265`。
- 多线程且支持 Range 时划分 8 段，否则一段；用 `RandomAccessFile.setLength(total)` 预分配，再以 `Range: bytes=start-end` 请求并 seek 写入。证据：`v4/j.smali:1262-1390,679-873`。
- 非 206 分片响应会报“服务器没有按分片返回”；416 将当前分片视为已完成；网络异常每片最多 6 次、退避 1.5s 递增，仍失败则标记下载失败并保留已下字节供“继续”。证据：`v4/j.smali:723-808,971-1049`。
- 暂停会递增任务代数并取消 coroutine/分片，保存进度；继续沿用现有分片。全部完成才置状态 3，否则部分分片失败置状态 4。证据：`v4/j.smali:1570-1636,1917-2022,2041-2264`。
- 移除任务同时取消、删除文件、删除 JSON；“清除已完成”代码实际筛选状态 **3 和 4**，因此也会删除失败任务及其文件，不仅是成功任务。证据：`v4/j.smali:1815-1905`、`z4/e0.smali:220-273`。

### 5.3 打开与安装

- 普通完成文件点击“打开”：确认文件存在，使用 `<package>.fileprovider` 生成 Uri，按扩展名/ContentResolver 推 MIME，发 `ACTION_VIEW` + `FLAG_GRANT_READ_URI_PERMISSION` + `FLAG_ACTIVITY_NEW_TASK`；文件丢失或无处理应用分别 Toast。证据：`z4/a1.smali:89-198,200-349`。
- APK 更新/GalBuilt 安装使用专用 `application/vnd.android.package-archive` intent，并交系统安装器；不是静默安装。证据：`x4/t.smali:800-853`。
- 应用更新包保存到 `getExternalFilesDir(null)/update/GalNook-<版本>.apk`（外部目录不可用时 filesDir/update），版本空则 `latest`，至少 1 KiB；自动打开安装器失败会保留路径并显示错误。证据：`f0/e0.smali:400-455,754-781`、`f0/w.smali:1693-1853`。关于页另有“系统下载”路径，完成后点通知安装：`z4/i2.smali:613-639`。

### 5.4 GalBuilt 下载与启动（不是本地模式本体）

- 设置入口先尝试包名 **`com.galbilt`** 的 launch intent（smali 原文就是这个拼写，复刻时建议同时核对 GalBuilt 实际包名），成功则启动，失败打开安装引导。证据：`z4/u.smali:41-125`、`z4/h.smali:47-59`。
- 引导明确说明扫描、引擎识别、游玩时长都在 GalBuilt，分开安装/更新；显示下载百分比和错误。证据：`z4/e.smali:183-241,291-440,456-520`。
- 下载地址按顺序为 `GalBuilt.apk`、`app-release.apk`、`built-release.apk`，均指向 `Xiao-youyu/GalBuild/releases/latest/download/`。保存为 `cacheDir/GalBuilt.apk`，每个候选失败清零进度再试，文件不足 1,000,000 字节视为不完整。证据：`z4/u.smali:22-36`、`f0/z0.smali:397-478,581-626,689-740`。成功后自动调用上述系统安装 intent：`f0/w.smali:1080-1191`。

## 6. 本地数据结构与缓存

数据库为 `galnook.db`，SQLite 版本 6，由 Application 创建。证据：`com/galnook/GalNookApp.smali:95-117`。表如下：

| 表 | 关键字段与用途 | 证据 |
|---|---|---|
| `works` | id、标题/中文名、会社、日期、封面、原语言、分级、简介、latin、play_minutes、refs、source、extras、cached_at | `v4/l.smali:1854-1856` |
| `work_tags` | work_id、tag_id、name、is_sexual | `v4/l.smali:1858-1860` |
| `work_ratings` | 每作品每来源 score/scale/votes | `v4/l.smali:1862-1864` |
| `work_characters` | work_id、char_id、name、image_url | `v4/l.smali:1866-1868` |
| `records` | state、favorite、score、updated_at，支撑个人记录 | `v4/l.smali:1870-1872` |
| `recent` | work_id、viewed_at，支撑最近浏览 | `v4/l.smali:1874-1876` |
| `reviews` | score、content、spoiler、created_at | `v4/l.smali:1878-1880`；读取：`k4/c.smali:3837-4006` |
| `routes` | 作品、角色、标题、状态、updated_at、source/source_url/walkthrough_id | `v4/l.smali:1882-1884` |
| `route_nodes` | 路线节点、条件、顺序、备注、步骤类型、替代项 | `v4/l.smali:1886-1888` |
| `speed_cache` | 每作品测速时间和 JSON | `v4/l.smali:1890-1892`；写入：`x4/p.smali:236-330` |

其他持久化边界：

- 作品详情成功加载会写 works 缓存并写 recent；网络失败但有缓存时也写 recent，404 转成“条目可能合并或删除”。证据：`k4/c.smali:850-919`。
- 个人记录查询联合作品缓存，按 updated_at 倒序 LIMIT 200。证据：`k4/c.smali:350-383`。
- 清缓存只删 works/tags/ratings/characters，不删 records/recent/reviews/routes。证据：`x4/o.smali:207-252`。
- 升级会清部分作品缓存；v6 清理空/null 路线节点和 null 条件。证据：`v4/l.smali:1905-2056`。

## 7. 免责声明、内容限制与错误处理

### 7.1 首次免责声明

首次启动读取 `disclaimer_accepted=false` 并展示协议，按钮为“拒绝并退出 / 同意并继续”；同意后持久化 true。证据：`f0/o.smali:2898-2918`、`t0/t.smali:2301-2385`、`t4/b.smali:125-144,201-215`。协议七项应原样进入 iOS 审查清单：

1. 仅 Galgame 信息索引与个人记录，不存储/托管/传播游戏本体、破解或汉化补丁。
2. NextMoe、VNDB、月幕、CnGal、SearchGal 数据可能延迟、缺失、机翻或错误，不保证完整/准确/时效。
3. 下载、商店、词条均为第三方链接，第三方行为与责任由第三方条款约束。
4. 用户承诺合法使用并自行承担后果。
5. 默认过滤成人内容；未满 18 岁不得开启，开启者自行判断。
6. 在法律允许范围内排除直接/间接/附带等损害赔偿。
7. 继续使用视为接受；不同意则停止使用并卸载。

完整原文证据：`t2/x.smali:809`；第三方资源站另有“只做索引，不托管不传播”弹窗：`t2/x.smali:1047-1123`。

### 7.2 R18 与搜索关键词

- 默认关闭；内容页说明开启后列表/详情显示敏感作品和封面，确认按钮带倒计时，倒计时结束才可开启。证据：`z4/b0.smali:743-819`、`t0/j.smali:836-906`、`z4/w.smali:496-565`。
- 详情若命中 R18 而当前未开，会询问是否去内容页；攻略也区分“确实无攻略”和“被 R18 过滤”。证据：`t4/c.smali:96-136`、`z4/k.smali:549-586`。
- 搜索框在 nsfw 关闭且输入至少 2 字时检测硬编码 R18 关键词，命中弹提示；不是只做服务端过滤。证据：`z4/c2.smali:75-105,123-239`。

### 7.3 错误呈现与恢复

- **通用错误模型**：HTTP 异常标题为 `请求失败 (HTTP n)`，响应正文最多 600 字符；无消息回退“网络不可用”，其他异常回退 message 或类名。证据：`u4/g.smali:13-100`。
- **错误报告**：报告包含标题、详情、异常类/message 和最多 4000 字符堆栈，可复制后关闭。证据：`b0/f.smali:944-1049`。
- **上次崩溃**：默认 uncaught handler 将堆栈写 `filesDir/last_crash.txt` 后交原 handler；下次启动读取并删除该文件，弹“上次运行出错了”供复制。证据：`v4/a.smali:30-128`、`f0/o.smali:2947-3065`、`t4/c.smali:1482-1528`。
- **作品加载**：无数据时说明可能网络/源不可用并提供重试；404 明确条目可能合并/删除；主源失败可自动切次源并显示来源。证据：`z4/d0.smali:354-424`、`k4/c.smali:877-919`、`y4/c.smali:272-340`。
- **WebView**：只对主框架记录错误，网络错误与 HTTP 状态分别呈现。证据：`z4/s.smali:134-226`。
- **下载**：缺 Content-Length、非 206、分片多次失败、部分分片失败均有专门错误；失败任务可从已写位置继续。证据：`v4/j.smali:767-808,1033-1049,1252-1260,1434-1450,2216-2262`。
- **网盘**：涵盖未识别、提取码错误/需要提取码、Cookie 失效、需登录、分享为空、文件 ID 缺失、直链缺失、游客上限等；典型分支见 `j3/a.smali:265-286,496-506,739-776,1390-1429,1804-1845`、`v4/v.smali:1740-1789,2608-2639,3793-3826`。UI 可复制解析错误：`z4/o1.smali:237-280`。
- **外部应用**：无浏览器、文件已移动/删除、无对应打开应用、游戏启动失败均 Toast，不静默吞掉。证据：`i4/o.smali:82`、`z4/a1.smali:287-349`、`b0/f.smali:679-703,730-777`。

## 8. 关于页、更新与反馈

- 关于页展示 GalNook / Galgame 作品库 / 当前 1.1.25；可复制版本、包名和 SDK 信息。证据：`z4/x.smali:2604-2652`、`z4/o1.smali:87-107`。
- 检查更新读取 `Xiao-youyu/GalNook` GitHub Release，显示发布时间、更新说明、最新/失败状态；可跳过该版本。证据：`g6/u.smali:38-45`、`z4/i2.smali:93-133,343-398,486-494`、`z4/z.smali:370`。
- 新包可应用内下载后安装，或交系统下载；显示进度和安装按钮。证据：`z4/w.smali:97-105,255-286`、`f0/e0.smali:400-455`、`z4/i2.smali:613-639`。
- 赞助只展示赞赏码，无额外功能；QQ 交流群通过浏览器打开。证据：`z4/a0.smali:843-901,1184-1242`。

## 9. iOS 实施顺序建议（按依赖落地）

1. **导航与数据模型**：实现 4 个主 tab + 上述 18 个路由语义；建立 Work/Record/Recent/Review/Route/RouteNode/DownloadTask/Settings 模型。特别注意 recent 是浏览记录，play time 不归 GalNook。
2. **作品浏览链路**：首页四区、搜索筛选、详情五页签、标签页、主/次源错误状态与缓存。
3. **个人记录**：状态/评分/最近浏览优先；独立收藏、评论新增和完整备份导入导出需作为“Android 缺陷复核后补齐”单独验收，不能照 UI 文案假报已完成。
4. **攻略**：远程角色线预览、选择导入、本地节点编辑、离线路线；iOS 用应用内浮层/ Live Activity 等平台能力替代 Android 系统悬浮窗，交互保留关闭、移动、缩放、正文滚动。
5. **下载器**：严格按第 5 节实现应用专属目录、命名、JSON 任务恢复、Range 探测、8 分片、暂停继续、打开/删除；系统安装只能复刻为 iOS 所允许的打开/分享行为，不能照搬 APK 安装语义。
6. **网盘与账号**：按站点独立 parser、Cookie/token 存储、登录页、错误分类；不要实现成一个无法维护的通用网页刮取器。
7. **设置与系统边界**：保留上表键名/默认值方便迁移；Android 专属权限、FileProvider、预测性返回、莫奈色、APK 安装应做 iOS 能力映射，而不是生成无效开关。
8. **GalBuilt 边界**：若 iOS 复刻只针对 GalNook，应保留“独立本地应用”入口和职责说明；若决定把 GalBuilt 也合并进 iOS，必须另立扫描、引擎识别、游玩时长需求，不能从本 APK 虚构这些实现。
