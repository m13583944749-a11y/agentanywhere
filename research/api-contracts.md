# GalNook API 逆向契约（APK 1.1.25）

> 目标：为 iOS/Swift 复刻提供可直接落地为 `Codable` 的请求、响应和凭证存储契约。
>
> 证据均来自只读 APK 的 smali。本文中的路径以 `/root/workspace/galnook-analysis/` 为根，例如 `smali/smali/g6/u.smali:69-535`。`dex-strings.txt` 仅用于交叉检查，不代替控制流证据。
>
> “实测”只记录本次会话真实访问公开接口得到的 HTTP 状态和字段；没有分享样本或用户 Cookie/token 的网盘流程均未做在线验证，不虚构响应。DTO 覆盖 APK 实际消费的字段，服务端额外字段应由 `JSONDecoder` 忽略。

## 0. 总结：鉴权与实现边界

| 服务 | 鉴权 | 用户是否需要提供凭证 |
|---|---|---|
| NextMoe | 无 | 否 |
| VNDB Kana | 无 token；JSON POST | 否 |
| Ymgal | OAuth2 `client_credentials`，随后 `Authorization: Bearer …`、`version: 1` | APK 内置公共 client；用户配置项存在但未接入请求 |
| CnGal | 无 | 否 |
| SearchGal | 无；form POST + SSE | 否；实例地址可配置 |
| GitHub Update | 无 token；`Accept: application/vnd.github+json` | 否 |
| 夸克 / UC | 分享 `stoken`；可选 Cookie，部分文件必须登录 | 公开分享可先游客尝试；遇到要求登录/限额时必须用户 Cookie |
| 百度 | `randsk` 转 `BDCLND`；列表/下载通常还要账号 Cookie | 经常需要用户 Cookie；`errno=-6` 明确要求登录 |
| 115 | 必须账号 Cookie | 必须 |
| 123 | 必须 `authorToken` Bearer；另有请求签名 | 必须 |
| 蓝奏 / 蓝奏优享版 | 页面参数与 `ajaxm.php`；无账号 Cookie 被发送 | 通常否；页面结构变化时可能要求用户在 Web 登录 |
| 迅雷 / 139 / 光年 | APK 没有内置直链 API 实现 | 只有登录/浏览器入口，不能复刻出虚构的解析接口 |

网盘识别与“是否有解析器”不是一回事：迅雷和 139 会识别链接，但默认分支返回“还没有内置解析客户端”；光年只有账号登录入口，未出现在 `Lv4/v` 的分享识别列表。证据：`smali/smali/v4/v.smali:72-222`、`smali/smali/j3/a.smali:1962-1996`、`smali/smali/v4/s.smali:68-104`。

---

## 1. 通用 HTTP 与 Swift 解码基础设施

### 1.1 普通 JSON helper

APK 的普通 helper 使用 `HttpURLConnection`：

- GET：无 body；JSON POST：`Content-Type: application/json`；form POST：`Content-Type: application/x-www-form-urlencoded`。
- 默认 header：
  - `User-Agent: GalNook/1.1.25 (Android; +https://galnook.app)`
  - `Accept: application/json`
  - `Accept-Encoding: gzip`
- 自动跟随重定向；connect/read 使用同一个 timeout。常见默认 15,000 ms；NextMoe 作品详情/攻略列表 45,000 ms，角色 30,000 ms，Ymgal 搜索 15,000 ms，网盘若干请求 20,000/25,000 ms。
- 2xx 读取 body；非 2xx 读取 error body 后抛带 HTTP status 和 body 的异常；gzip 仅在 `Content-Encoding == gzip` 时解压。

证据：`smali/smali/u4/g.smali:103-147`、`327-395`、`395-478`、`480-768`。

夸克/UC 使用单独 helper，**不是**上面的 UA：固定桌面 UA、`Origin`、`Referer`、可选 `Cookie`，不自动跟随重定向；保留 HTTP status/body，并从 `Set-Cookie` 中提取 `__pugs=`。证据：`smali/smali/v4/v.smali:828-1142`。

### 1.2 Codable 约定

建议 response DTO 使用下划线转驼峰；`FileID`、`DownloadURL`、`S3KeyFlag`、`InfoList`、`SharePwd` 等必须显式 `CodingKeys`。Android `JSONObject.optString` 会把部分数字也转成字符串，因此网盘 ID、大小和目录标志不能一律假设 JSON 类型稳定。

```swift
import Foundation

let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

struct APIError: Error {
    let status: Int          // 网络层错误可用 -1
    let body: String
}

// 用于 SearchGal progress、未消费扩展字段等。
enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// optString 兼容层：string/number/bool 都能读成字符串。
struct LooseString: Codable, Hashable {
    let value: String
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Int64.self) { value = String(v) }
        else if let v = try? c.decode(Double.self) { value = String(v) }
        else if let v = try? c.decode(Bool.self) { value = String(v) }
        else { value = "" }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(value)
    }
}
```

下面 `items`、 `result`、 `list` 等数组在 Android 中缺失时通常按 `[]` 处理。iOS 可用 `decodeIfPresent(...) ?? []`；为简洁，DTO 中部分数组标为 optional，映射到领域模型时补空数组。

---

## 2. NextMoe

### 2.1 Base URL、header 和配置

- 作品/标签/公司默认 base：`https://api.nextmoe.dev`。
- 攻略客户端固定 base：`https://api.nextmoe.dev/v2`。
- `api_base_host` 可覆盖作品客户端 host，空白回退默认值；攻略 base 未见同样的覆盖注入。
- 使用第 1 节普通 header，无 Authorization/Cookie。

证据：`smali/smali/k4/c.smali:161-256`、`smali/smali/x4/t.smali:638-690`、`smali/smali/v4/e0.smali:13-23`。

### 2.2 作品搜索/榜单

`GET {base}/v2/catalog/works`

Query（先 URL encode，再以 `&` 拼接）：

| 参数 | 类型/默认 | 说明 |
|---|---|---|
| `limit` | Int，默认 24 | 每页数量 |
| `include` | String，固定 `titles,covers,ratings` | 搜索/列表 |
| `nsfw` | Bool，默认 false | 小写 `true/false` |
| `q` | String? | 搜索词；非空才发送 |
| `sort` | String? | 默认 popularity；有 q 时 popularity 改 relevance；`all` 不发送 |
| `cursor` | String? | 下一页游标 |
| `tag_id` | String? | 标签过滤 |
| `olang` | String? | 原始语言 |
| `platform` | String? | 平台 |
| `year` | Int? | 年份 |
| `score_min` | Double? | 最低评分 |

Response：`items` + 可空 `next_cursor`。作品摘要实际读取 `id/display_name/localized/release_date/cover.url/companies/ratings`。

证据：`smali/smali/g6/u.smali:69-535`；作品字段：`1141-1281`；评分：`903-1139`。

```swift
struct NMPage<Item: Decodable>: Decodable {
    let object: String?
    let items: [Item]?
    let nextCursor: String?
}

struct NMLocalizedValue: Decodable { let value: String? }
typealias NMLocalized = [String: NMLocalizedValue]

struct NMImage: Decodable { let url: String? }

struct NMRating: Decodable {
    let source: String
    let score: Double
    let voteCount: Int?
}

struct NMCompany: Decodable {
    let id: String?
    let displayName: String?
    let localized: NMLocalized?
    let companyKind: String?
    let attributionRole: String?
}

struct NMWork: Decodable {
    let object: String?
    let id: String
    let medium: String?
    let displayName: String?
    let latin: String?
    let localized: NMLocalized?
    let olang: String?
    let contentRating: String?
    let contentLimit: String?
    let releaseDate: String?
    let releaseDatePrecision: String?
    let releaseStatus: String?
    let cover: NMImage?
    let banner: NMImage?
    let coverSfw: NMImage?
    let companies: [NMCompany]?
    let ratings: [NMRating]?
    let tags: [NMTag]?
    let intros: [NMIntro]?
    let refs: [NMRef]?
    let relations: [NMRelation]?
    let playtimes: [NMPlaytime]?
}

struct NMTag: Decodable {
    let id: String
    let displayName: String?
    let isSexual: Bool?
}

struct NMIntro: Decodable {
    let lang: String?
    let value: String?
    let source: String?
    let isMachine: Bool?
}

struct NMRef: Decodable {
    let source: String?
    let externalId: String?
}

struct NMPlaytime: Decodable { let minutes: Int? }

struct NMRelation: Decodable {
    let relationType: String?
    let phrase: String?
    let work: NMRelatedWork?
}
struct NMRelatedWork: Decodable {
    let id: String
    let displayName: String?
    let localized: NMLocalized?
    let cover: NMImage?
}
```

评分映射不是网络字段：NextMoe/Bangumi scale=10，VNDB/Steam/ErogameScape scale=100，DLsite scale=5；其他来源按 score≤5、≤10、否则 100 推断。证据：`smali/smali/g6/u.smali:962-1116`。

### 2.3 标签与公司目录

- `GET {base}/v2/catalog/tags?limit=80`
  - response 同 `NMPage<NMTag>`；APK 读取 `items` 和 `next_cursor`，但当前返回流程未继续消费游标。
- `GET {base}/v2/catalog/companies?limit=80`
  - response 同 `NMPage<NMCompany>`。

证据：`smali/smali/t4/t.smali:626-901`。

### 2.4 作品完整详情、角色、外链

1. `GET {base}/v2/catalog/works/{workId}?view=full&include=tags,intros,relations,covers,playtimes&nsfw={bool}`
   - 单对象 `NMWork`，不是 `items` 包装。
   - 404 且最初 `nsfw=true` 时会以 `nsfw=false` 重试。
   - `refs: [{source, external_id}]`、`relations: [{relation_type, phrase, work}]`、`playtimes: [{minutes}]`。
2. `GET {base}/v2/catalog/works/{workId}/characters?limit=40&nsfw={bool}`
   - `items: [NMCharacter]`；最多请求 40，失败/空结果最多两轮。
3. `GET {base}/v2/catalog/works/{workId}/links`
   - 无 query；数组优先取 `items`，缺失则取 `links`。
   - 每项 `url` 必需；显示名取 `label`，空则取 `site`，再空由 UI 给默认值。

证据：详情 `smali/smali/g6/u.smali:1927-1968`、`2107-3030`；角色 `1451-1925`；链接 `smali/smali/k4/c.smali:2846-3055`。

```swift
struct NMVoice: Decodable {
    let name: String?
    let displayName: String?
    let label: String?
}
struct NMCharacter: Decodable {
    let id: String
    let displayName: String?
    let localized: NMLocalized?
    let image: NMImage?
    let figure: NMImage?
    let description: String?
    let intro: String?
    let voices: [NMVoice]?
}
struct NMLink: Decodable {
    let label: String?
    let site: String?
    let url: String
}
```

角色图片优先 `figure.url`，否则 `image.url`；声优名依次取 `name/display_name/label`。简介优先 `description`，空则 `intro`。

### 2.5 攻略列表与完整 chart

- `GET https://api.nextmoe.dev/v2/catalog/walkthroughs?work_id={workId}&limit=20[&nsfw=true]`
  - response：`items: [NMWalkthroughSummary]`。
  - 若 nsfw=false 无结果，APK 会用 nsfw=true 再试，并标记结果含 R18 内容；列表请求失败会隔 800 ms 重试一次。
- `GET https://api.nextmoe.dev/v2/catalog/walkthroughs/{id}?view=full[&nsfw=true]`
  - response：单对象；根对象同时含 summary 字段、`chart` 和 `entries`。

证据：`smali/smali/v4/e0.smali:25-324`、`328-624`；详情 `smali/smali/k4/c.smali:4557-5542`。

```swift
struct NMWtCharacter: Decodable {
    let key: String
    let displayName: String?
    let name: String?
    let localized: NMLocalized?
    let characterId: String?
}

struct NMWalkthroughSummary: Decodable {
    let id: String
    let workId: String
    let source: String?
    let sourceUrl: String?
    let sourceAuthor: String?
    let sourceUpdatedOn: String?
    let lang: String?
    let endingCount: Int?
    let saveCount: Int?
    let segmentCount: Int?
    let characters: [NMWtCharacter]?
}

struct NMWalkthroughDetail: Decodable {
    // 根对象也带 summary 字段；可扁平继承/组合 NMWalkthroughSummary 的解码逻辑。
    let id: String
    let workId: String
    let source: String?
    let sourceUrl: String?
    let sourceAuthor: String?
    let sourceUpdatedOn: String?
    let lang: String?
    let endingCount: Int?
    let saveCount: Int?
    let segmentCount: Int?
    let characters: [NMWtCharacter]?
    let chart: NMWalkthroughChart?
    let entries: [NMWalkthroughEntry]?
}

struct NMWalkthroughEntry: Decodable {
    let label: String?
    let localized: NMLocalized?
}
struct NMWalkthroughChart: Decodable {
    let sections: [NMWtSection]?
    let endings: [NMWtEnding]?
    let segments: [NMWtSegment]?
}
struct NMWtSection: Decodable {
    let key: String
    let title: String?
    let localized: NMLocalized?
    let characterKeys: [String]?
}
struct NMWtEnding: Decodable {
    let key: String
    let name: String?
    let localized: NMLocalized?
    let endingType: String? // bad/normal/heroine/true；其他值保留
    let characterKeys: [String]?
}
struct NMWtNode: Decodable {
    let key: String?
    let nodeType: String?
}
struct NMWtStep: Decodable {
    let stepType: String?
    let text: String?
    let remark: String?
    let saveKey: String?
    let localized: NMLocalized?
    let alternatives: [NMWtAlternative]?
}
struct NMWtAlternative: Decodable {
    let text: String?
    let localized: NMLocalized?
}
struct NMWtSegment: Decodable {
    let key: String
    let sectionKey: String?
    let condition: String?
    let conditionLocalized: NMLocalized?
    let localized: NMLocalized?
    let fromNode: NMWtNode?
    let toNode: NMWtNode?
    let requiresEndingKeys: [String]?
    let steps: [NMWtStep]?
}
```

中文 localized 取值顺序为 `zh-Hans → zh-Hant → zh`；攻略步骤文本和 alternatives 会过滤空白及字符串 `"null"`。`entries` 只取第一项作为入口标签。证据：`smali/smali/v4/e0.smali:25-100`、`smali/smali/k4/c.smali:4974-5539`。

---

## 3. VNDB Kana

### 3.1 请求

Base：`https://api.vndb.org/kana/vn`。三种调用都为 **POST JSON**，无 token，使用普通 GalNook header，timeout 15 s。

共同 fields（原样逗号分隔）：

```text
id,title,alttitle,image.url,image.thumbnail,released,rating,votecount,developers.name,titles.lang,titles.title,titles.latin
```

| 场景 | JSON body |
|---|---|
| 搜索 | `{"filters":["search","=",query],"fields":FIELDS,"results":limit,"sort":"searchrank"}` |
| 评分榜 | `{"filters":[],"fields":FIELDS,"results":limit,"sort":"rating","page":page}` |
| 按 ID | `{"filters":["id","=",vndbId],"fields":FIELDS,"results":1}` |

证据：`smali/smali/g6/u.smali:1373-1448`、`1971-2105`。

```swift
struct VNDBRequest: Encodable {
    let filters: [JSONValue] // 搜索时也可定义 [String]；空数组表示无过滤
    let fields: String
    let results: Int
    let sort: String
    let page: Int?
}

struct VNDBResponse: Decodable {
    let more: Bool?
    let results: [VNDBVisualNovel]?
}
struct VNDBVisualNovel: Decodable {
    let id: String
    let title: String?
    let alttitle: String?
    let image: VNDBImage?
    let released: String?
    let rating: Double?
    let votecount: Int?
    let developers: [VNDBDeveloper]?
    let titles: [VNDBTitle]?
}
struct VNDBImage: Decodable {
    let url: String?
    let thumbnail: String?
}
struct VNDBDeveloper: Decodable { let name: String? }
struct VNDBTitle: Decodable {
    let lang: String?
    let title: String?
    let latin: String?
}
```

Response 以 `results` 为列表。APK 将 id 变成内部 `vndb:{id}`，取中文标题时找 `titles[].lang == zh-Hans` 或 `zh`，公司取 `developers[0].name`，评分直接使用 VNDB 的 100 分制。证据：`smali/smali/g6/u.smali:538-901`。

---

## 4. Ymgal（月幕）

### 4.1 OAuth token

`GET https://www.ymgal.games/oauth/token`

Query：

```text
grant_type=client_credentials
client_id={URL-encoded client id}
client_secret={URL-encoded client secret}
scope=public
```

APK 内置值为 `client_id=ymgal`、`client_secret=luna0327`，不是用户 Cookie。token 只保存在内存，提前 60 秒过期；`expires_in` 缺失默认 3600，且最小按 60 秒处理。证据：`smali/smali/v4/f0.smali:19-36`、`41-246`。

```swift
struct YmgalToken: Decodable {
    let accessToken: String
    let scope: String?
    let tokenType: String?
    let expiresIn: Int?
}
```

### 4.2 搜索与 archive

两个请求都带：

```text
Accept: application/json;charset=utf-8
Authorization: Bearer {access_token}
version: 1
```

同时继承普通 helper 的 GalNook UA 和 gzip（调用方 header 覆盖 Accept）。

1. `GET /open/archive/search-game?mode=list&keyword={encoded}&pageNum=1&pageSize={1...20}`
   - `success == false` 或 `data/result` 缺失时按空列表。
2. `GET /open/archive?gid={Int64}`
   - 读取 `data.game`；简介顺序为 `introduction → intro → intros` 中 `lang=zh-Hans` 的 `value`。

证据：`smali/smali/v4/f0.smali:41-228`、`248-495`、`497-764`。

```swift
struct YmgalEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let code: Int?
    let data: T?
}
struct YmgalSearchData: Decodable {
    let result: [YmgalGame]?
    let total: Int?
    let hasNext: Bool?
    let pageNum: Int?
    let pageSize: Int?
}
struct YmgalGame: Decodable {
    let id: Int64
    let name: String
    let chineseName: String?
    let orgName: String?
    let releaseDate: String?
    let mainImg: String?
    // 实测还存在 state/weights/publishVersion/publishTime/publisher/score/orgId/haveChinese。
}
struct YmgalArchiveData: Decodable { let game: YmgalArchiveGame? }
struct YmgalArchiveGame: Decodable {
    let introduction: String?
    let intro: String?
    let intros: [YmgalIntro]?
}
struct YmgalIntro: Decodable {
    let lang: String?
    let value: String?
}
```

**配置的实际情况**：`galnook.settings` 的 `ymgal_id`、`ymgal_secret` 会读写并显示在设置状态，但全 smali 中对 `Lv4/f0` 的 client id/secret 只有构造器内常量，未见设置注入。因此复刻“当前 APK 行为”用内置公共 client；若 iOS 开放自定义 client，应把它作为新实现并安全存储，不要误认为 APK 已使用用户值。证据：`smali/smali/x4/t.smali:422-451`、`smali/smali/o/f0.smali:95-145`，对照 `smali/smali/v4/f0.smali:19-36`。

---

## 5. CnGal

Base：`https://api.cngal.org`，无鉴权，普通 GET，timeout 25 s。

1. `GET /api/entries/GetAllEntriesIdName`
   - response 是**顶层数组**，每项 `{id:Int, name:String}`。
   - 在内存缓存 86,400,000 ms（24 h）；先 trim + 小写精确匹配，再做双向 contains 匹配。
2. `GET /api/entries/GetEntryView/{id}?renderMarkdown=false`
   - response 单对象，APK 只取 `id/name/anotherName/briefIntroduction`；`id<=0` 视为无效。

证据：`smali/smali/d2/d.smali:38-52`、`57-245`、`246-479`。

```swift
struct CnGalIDName: Decodable {
    let id: Int
    let name: String
}
struct CnGalEntry: Decodable {
    let id: Int
    let name: String
    let anotherName: String?
    let briefIntroduction: String?
}
```

---

## 6. SearchGal

### 6.1 请求与实例选择

`POST {searchgalBase}/gal`

- 默认 base：`https://vercel.api.searchgal.top`；`searchgal_base` 可覆盖，base 末尾 `/` 会 trim。
- body：`game={URLEncoded keyword}`。
- `Content-Type: application/x-www-form-urlencoded`；普通 helper 还发送 GalNook UA、`Accept: application/json`、gzip。
- timeout 90,000 ms（`0x15f90`）。
- `only_searchgal=true` 只查配置实例；false 时还会顺序查内置补缺点 `https://gal.0721ciallo.top`。

证据：`smali/smali/v4/c0.smali:11-65`、`smali/smali/k4/c.smali:3608-3834`；默认配置 `smali/smali/x4/t.smali:638-654`。

### 6.2 响应不是普通 JSON，而是逐行事件

实测 `Content-Type: text/event-stream; charset=utf-8`。Android 实际按“每行 trim → 去掉可选 `data:` 前缀 → 行首为 `{` 时解析 JSON”处理；不要仅用整包 `JSONDecoder` 解码，也不要假设一定有 SSE 空行。

事件形态：

- `{"total":26}`（本次实测值，仅说明类型）
- `{"progress":{...}}`；保留为 `JSONValue`，当前 APK 不消费。
- `{"result":{"name":...,"color":...,"tags":[...],"items":[...]}}`

只有 `result.items` 非空的 result 会形成资源站；URL 全局去重，每个站最多取 40 条，站点名空时为“资源站”。`tags` 为字符串数组，`items` 每项 `{name,url}`。

证据：`smali/smali/v4/c0.smali:68-120`、`100-371`。

```swift
struct SGEvent: Decodable {
    let total: Int?
    let progress: JSONValue?
    let result: SGResult?
}
struct SGResult: Decodable {
    let name: String?
    let color: String?
    let tags: [String]?
    let items: [SGItem]?
}
struct SGItem: Decodable {
    let name: String?
    let url: String
}

func decodeSearchGalLine(_ line: String) throws -> SGEvent? {
    var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("data:") {
        text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
    guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
    return try decoder.decode(SGEvent.self, from: data)
}
```

无需 Cookie/token。SearchGal 结果缓存于非凭证 `galnook.cache` 的 `sg_{workId}` JSON，不属于账号存储。证据：`smali/smali/v4/q.smali:18-28`、`55-88`。

---

## 7. GitHub 更新

### 7.1 最新 Release

`GET https://api.github.com/repos/Xiao-youyu/GalNook/releases/latest`

Header：`Accept: application/vnd.github+json`，另有普通 UA/gzip；无 Authorization；timeout 20 s。

Response 读取：

- `tag_name`（版本比较时去掉 v/V 和前缀 Beta-）
- `name`（空则回退 tag_name）
- `body`
- `html_url`
- `published_at`（ISO-8601 字符串）
- `assets[]`：选**第一个 name 以 `.apk` 结尾**（忽略大小写）的 `browser_download_url`

证据：`smali/smali/g6/u.smali:38-45`、`smali/smali/t4/t.smali:1148-1318`；版本比较 `smali/smali/x4/d.smali:148-224`。

```swift
struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let publishedAt: String?
    let assets: [GitHubAsset]?
}
struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
}
```

另有 GalBuild（不是 GalNook 自身 release API）固定下载候选，顺序为 `GalBuilt.apk → app-release.apk → built-release.apk`：

```text
https://github.com/Xiao-youyu/GalBuild/releases/latest/download/GalBuilt.apk
https://github.com/Xiao-youyu/GalBuild/releases/latest/download/app-release.apk
https://github.com/Xiao-youyu/GalBuild/releases/latest/download/built-release.apk
```

证据：`smali/smali/z4/u.smali:13-38`。

---

## 8. 网盘共享模型与最终下载请求

### 8.1 统一输出模型

```swift
struct PanFile: Codable {
    let name: String
    let url: String
    let size: String       // APK 已格式化为 B/KB/MB/GB；不是字节数
    let referer: String
}
enum PanResult {
    case success(site: String, note: String, files: [PanFile])
    case needLogin(site: String, message: String)
    case failure(site: String, message: String)
}
```

对应 smali：`PanFile` 为 `smali/smali/v4/t.smali:17-43`；success/needLogin/failure 为 `smali/smali/v4/y.smali:18-37`、`smali/smali/v4/x.smali:16-33`、`smali/smali/v4/w.smali:16-33`。

最终文件下载 helper 使用：

```text
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36
Referer: {PanFile.referer，非空才发送}
Range: {可选 Range}
```

自动跟随重定向，connect 15 s/read 30 s；**此 helper 不添加 Cookie**。证据：`smali/smali/v4/j.smali:1456-1509`。

### 8.2 账号凭证存储（Android 真值）

- 文件：私有 `SharedPreferences` **`galnook.pan_accounts`**，Application 启动时初始化。证据：`smali/smali/com/galnook/GalNookApp.smali:27-70`。
- key：
  - `quark`、`uc`、`baidu`、`pan115`、`xunlei`、`caiyun`、`guangya`、`ilanzou`、`pan123`：完整 Cookie 字符串（是否实际用于解析见各节）。
  - `pan123.token`：123 WebView `localStorage.authorToken`。
- Cookie 来源：WebView `CookieManager.getCookie(loginOrigin)`，按分号清理后以 `; ` 连接并写入上述 siteId key。证据：`smali/smali/v4/s.smali:378-552`、`smali/smali/g1/b.smali:150-225`。
- 123 token 来源 JS：`(function(){try{return localStorage.getItem('authorToken')||''}catch(e){return ''}})()`；保存 `pan123.token`，另外可保存 `pan123` Cookie。证据：`smali/smali/g1/b.smali:150-164`、`smali/smali/z4/l1.smali:94-155`。
- 夸克/UC 登录判定要求 Cookie 中有 `__pus=` 或 `__puus=`；注意响应 helper 另会跟踪 `__pugs=`，三者不是同一个 key。证据：`smali/smali/v4/s.smali:242-375`、`smali/smali/v4/v.smali:1057-1140`。
- 登出删除 siteId 与 `{siteId}.token`，并将 Web Cookie 设为 `Max-Age=0`。证据：`smali/smali/a0/i1.smali:172-334`。

iOS 对应建议：Cookie、authorToken、Ymgal 自定义 client secret 应放 Keychain；`searchgal_base`、NextMoe base 和布尔设置放 `UserDefaults`。不要把 token 拼进日志或持久化到资源缓存。

---

## 9. 夸克网盘与 UC 网盘

### 9.1 分享码与固定配置

从 URL 正则 `/s/([0-9A-Za-z_-]+)` 得 `pwd_id`，从 `[?&]pwd=([0-9A-Za-z]+)` 得 passcode。证据：`smali/smali/v4/v.smali:3013-3179`。

| 项 | 夸克 | UC |
|---|---|---|
| 分享页/Origin/Referer | `https://pan.quark.cn/`（Origin 无末尾 /） | `https://drive.uc.cn/` |
| UA | `quark-cloud-drive/2.5.20 … Electron/18.3.5.12-a038f7b798 … Channel/pckk_other_ch`（完整常量见下行证据） | `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36` |
| token | `https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc` | `https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc` |
| detail | `https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc` | `https://pc-api.uc.cn/1/clouddrive/share/sharepage/v2/detail?pr=UCBrowser&fr=pc` |
| download | `https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2` | `https://pc-api.uc.cn/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser` |
| PanFile.referer | `https://pan.quark.cn/` | `https://drive.uc.cn/` |

夸克完整 UA：

```text
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch
```

证据：`smali/smali/v4/v.smali:224-254`。

### 9.2 三步请求

**Step 1：换 stoken**

`POST tokenURL`，JSON：

```json
{
  "pwd_id": "分享码",
  "passcode": "提取码或空字符串",
  "support_visit_limit_private_share": true
}
```

Response：

```swift
struct QuarkTokenResponse: Decodable {
    let status: Int?
    let code: Int?
    let message: String?
    let data: QuarkTokenData?
}
struct QuarkTokenData: Decodable {
    let stoken: String
    let title: String?
}
```

`status != 200` 是失败；`code` 为 41004/41006 时 APK 归为需要提取码。成功要求非空 `data.stoken`。

**Step 2：列文件**

`GET detailURL + 以下 query`：

```text
pwd_id={pwd_id}
stoken={URL-encoded stoken}
pdir_fid=0
ver=2
force=0
_page=1
_size=100
_fetch_banner=0
_fetch_share=0
fetch_relate_conversation=0
_fetch_total=1
_sort=file_type:asc,file_name:asc
```

Response：`data.list`，跳过 `dir=true`：

```swift
struct QuarkListResponse: Decodable { let data: QuarkListData? }
struct QuarkListData: Decodable { let list: [QuarkListItem]? }
struct QuarkListItem: Decodable {
    let dir: Bool?
    let fid: LooseString
    let shareFidToken: String
    let fileName: String?
    let size: Int64?
}
```

**Step 3：每个文件取直链**

`POST downloadURL`，JSON：

```json
{
  "fids": ["fid"],
  "fids_token": ["share_fid_token"],
  "pwd_id": "分享码",
  "stoken": "stoken",
  "speedup_session": "",
  "token": ""
}
```

Response：

```swift
struct QuarkDownloadResponse: Decodable {
    let code: Int?
    let message: String?
    let data: [QuarkDownloadItem]?
}
struct QuarkDownloadItem: Decodable { let downloadUrl: String }
```

取 `data[0].download_url`。游客 `code=23026` 表示单文件上限并要求登录，`code=31001` 表示要求登录。请求顺序及字段证据：`smali/smali/v4/v.smali:3133-3442`、`3497-3719`、`3733-3925`。

三步都可能更新 Cookie：若响应 `Set-Cookie` 有 `__pugs=`，后续请求用它替代旧 Cookie；其他情况延续上一步 Cookie。所有 body 请求 `Content-Type: application/json`；GET 无 body。凭证不是必须预先存在，游客可尝试，失败时返回 `needLogin`。

---

## 10. 百度网盘

### 10.1 分享页、提取码与页面参数

分享码正则 `/s/([0-9A-Za-z_-]+)`，pwd 正则 `[?&]pwd=([0-9A-Za-z]+)`。基础 header：

```text
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
Referer: https://pan.baidu.com/
```

1. `GET https://pan.baidu.com/s/{shorturl}`：读取 HTML，初访不额外添加账号 Cookie。
2. 从 HTML 正则提取：
   - `"timestamp"\s*:\s*(\d{9,})`
   - `"sign"\s*:\s*"([0-9a-fA-F]+)"`
   - `"shareid"\s*:\s*(\d+)`
   - `"uk"\s*:\s*(\d+)`
3. 若需提取码：

`POST https://pan.baidu.com/share/verify?surl={shorturl}`

form body：

```text
pwd={URL-encoded pwd}&vcode_str=&vcode=
```

额外 header：`Content-Type: application/x-www-form-urlencoded`、`Referer: https://pan.baidu.com/s/{shorturl}`；有账号 Cookie 时加 `Cookie: {baidu}`。

```swift
struct BaiduVerifyResponse: Decodable {
    let errno: Int
    let randsk: String?
}
```

`errno` 必须 0；随后再以 `Cookie: BDCLND={URL-encoded randsk}` GET 分享页并重新提取 sign/timestamp。证据：`smali/smali/j3/a.smali:579-735`、`782-1250`。

### 10.2 列表

`GET https://pan.baidu.com/rest/2.0/xpan/share`

Query（按 URL 组合，短码本身不再二次编码）：

```text
method=list
shorturl={shorturl}
page=1
num=100
root=1
dir=%2F
```

Header：上述 Chrome UA，`Referer` 为分享页，账号 `baidu` Cookie 非空才添加。Response：

```swift
struct BaiduListResponse: Decodable {
    let errno: Int
    let title: String?
    let list: [BaiduListItem]?
}
struct BaiduListItem: Decodable {
    let isdir: LooseString?       // "1" 表示目录
    let fsId: LooseString
    let size: Int64?
    let serverFilename: String?
}
```

`errno=-6` 明确要求登录。证据：`smali/smali/j3/a.smali:1265-1440`、`1476-1503`。

### 10.3 sharedownload

对每个非目录文件：

`GET https://pan.baidu.com/api/sharedownload`

Query：

```text
sign={HTML sign}
timestamp={HTML timestamp}
fid_list={URL-encoded JSON 数组，例如 "[123456]"}
uk={HTML uk}
primaryid={HTML shareid}
channel=chunlei
web=1
app_id=250528
clienttype=0
```

Header 同列表。Response 兼容两种形态：

```swift
struct BaiduDownloadResponse: Decodable {
    let errno: Int
    let dlink: String?
    let list: [BaiduDownloadItem]?
}
struct BaiduDownloadItem: Decodable { let dlink: String? }
```

`errno==0` 时先取根 `dlink`，空则取 `list[0].dlink`。文件名取列表 `server_filename`，大小取 `size`，`PanFile.referer=https://pan.baidu.com/`。证据：`smali/smali/j3/a.smali:1491-1589`、`1639-1767`。

账号 Cookie 存于 `galnook.pan_accounts["baidu"]`；无 Cookie 可以尝试，但列表/直链返回登录错误时必须转为用户登录流程，不能伪造 BDCLND。

---

## 11. 115 网盘

必须 `galnook.pan_accounts["pan115"]` Cookie，否则直接 `needLogin`，不会请求分享 API。分享码 `/s/([0-9a-zA-Z]+)`，提取码参数支持 `password` 或 `pwd`。证据：`smali/smali/v4/v.smali:1803-1929`。

### 11.1 动态 UA

先 `GET https://appversion.115.com/1/web/1.0/api/chrome`，取 `data.win.version_code`，失败/空时回退 `36.0.1`。此请求用普通 GalNook header。随后 115 API header：

```text
User-Agent: Mozilla/5.0 115Browser/{version_code}
Referer: https://115.com/s/{share_code}[?password={pwd}]
Cookie: {pan115 Cookie}
```

证据：`smali/smali/v4/v.smali:1931-2092`。

```swift
struct ChromeVersionResponse: Decodable { let data: ChromeVersionData? }
struct ChromeVersionData: Decodable { let win: ChromeVersionWin? }
struct ChromeVersionWin: Decodable { let versionCode: String? }
```

### 11.2 分享列表

`GET https://webapi.115.com/share/snap`

Query：

```text
share_code={share_code}
receive_code={pwd，无则空}
offset=0
limit=100
asc=0
cid=0
format=json
```

Response：

```swift
struct Pan115SnapResponse: Decodable {
    let message: String?
    let data: Pan115SnapData?
}
struct Pan115SnapData: Decodable {
    let userinfo: Pan115UserInfo?
    let shareinfo: Pan115ShareInfo?
    let list: [Pan115File]?
}
struct Pan115UserInfo: Decodable { let userId: LooseString }
struct Pan115ShareInfo: Decodable { let shareTitle: String? }
struct Pan115File: Decodable {
    let isDir: Int?
    let fid: LooseString
    let n: String?
    let s: LooseString? // 文件大小字符串，转 Int64
}
```

需要 `userinfo.user_id`；`is_dir==1` 跳过。证据：`smali/smali/v4/v.smali:2094-2240`、`2253-2364`。

### 11.3 单文件直链

`GET https://webapi.115.com/share/downurl`

Query：

```text
dl=1
user_id={URL-encoded user_id}
share_code={URL-encoded share_code}
file_id={URL-encoded fid}
receive_code={URL-encoded pwd，仅非空时发送}
```

Header 与 snap 相同。Response：

```swift
struct Pan115DownloadResponse: Decodable { let data: Pan115DownloadData? }
struct Pan115DownloadData: Decodable {
    let fileUrl302: String?
    let fileUrl: String?
    let url: Pan115NestedURL?
    let fn: String?
}
struct Pan115NestedURL: Decodable { let url: String? }
```

直链优先级 `file_url_302 → file_url → url.url`；文件名可用 `fn` 覆盖，`PanFile.referer` 是带可选 password 的 115 分享页。证据：`smali/smali/v4/v.smali:2365-2578`。

---

## 12. 123 云盘

必须 `pan123.token`（Web `authorToken`）；没有则直接 `needLogin`。分享码 `/s/([0-9A-Za-z_-]+)`，pwd 支持 `pwd` 或 `password`。证据：`smali/smali/v4/v.smali:4114-4261`。

### 12.1 签名 header

所有 123 API 都带：

```text
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36
Referer: https://yun.123pan.cn/
Origin: https://yun.123pan.cn
platform: {见各请求}
app-version: {见各请求}
auth-key: {计算值}
auth-value: {计算值}
Authorization: Bearer {authorToken}
Content-Type: application/json
```

精确算法（UTF-8 CRC32，输出小写 hex，不补零）：

```text
now = floor(currentEpochSeconds)
expiryText = UTC(now + 3600) 格式化为 yyyyMMddHHmm
mapped = expiryText 的每个数字 d 替换为 alphabet[d]
alphabet = "adefghlmyijnopkqrstubcvwsz"
authKey = crc32Hex(mapped)
random = 0...9,999,999 的随机整数
signatureSource = "\(now)|\(random)|\(apiPath)|web|3|\(authKey)"
authValue = "\(now)-\(random)-\(crc32Hex(signatureSource))"
```

注意：即使 download 请求 header 是 `platform=android&app-version=39`，签名串仍硬编码 `|web|3|`。`apiPath` 分别是 `/b/api/share/get` 和 `/b/api/share/download/info`。证据：`smali/smali/v4/v.smali:259-295`、`2693-3011`。

### 12.2 分享列表

`GET https://yun.123pan.cn/b/api/share/get`

Query：`shareKey={encoded shareCode}`，有 pwd 再加 `SharePwd={encoded pwd}`。签名 header 使用 `platform=web`、`app-version=3`。

Response：`code==0` 才成功：

```swift
struct Pan123ShareResponse: Decodable {
    let code: Int
    let message: String?
    let data: Pan123ShareData?
}
struct Pan123ShareData: Decodable {
    let shareName: String?
    let infoList: [Pan123File]?

    enum CodingKeys: String, CodingKey {
        case shareName = "ShareName"
        case infoList = "InfoList"
    }
}
struct Pan123File: Decodable {
    let type: Int?
    let fileId: LooseString
    let s3KeyFlag: String?
    let size: Int64?
    let etag: String?
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case fileId = "FileId"
        case s3KeyFlag = "S3KeyFlag"
        case size = "Size"
        case etag = "Etag"
        case fileName = "FileName"
    }
}
```

`Type==1` 为目录并跳过。证据：`smali/smali/v4/v.smali:4263-4450`。

### 12.3 下载信息

`POST https://www.123865.com/b/api/share/download/info`

无额外 query；签名 header 使用 `platform=android`、`app-version=39`。body：

```json
{
  "ShareKey": "分享码",
  "FileID": "FileId 字符串",
  "S3KeyFlag": "原值或空字符串",
  "Size": 12345,
  "Etag": "原值或空字符串"
}
```

```swift
struct Pan123DownloadRequest: Encodable {
    let shareKey: String
    let fileID: String
    let s3KeyFlag: String
    let size: Int64
    let etag: String
    enum CodingKeys: String, CodingKey {
        case shareKey = "ShareKey", fileID = "FileID"
        case s3KeyFlag = "S3KeyFlag", size = "Size", etag = "Etag"
    }
}
struct Pan123DownloadResponse: Decodable { let data: Pan123DownloadData? }
struct Pan123DownloadData: Decodable {
    let downloadURL: String
    enum CodingKeys: String, CodingKey { case downloadURL = "DownloadURL" }
}
```

若 `DownloadURL` 含 `params=`，取该参数到下一个 `&` 前，URL decode + Base64 decode 成 JSON，再读 `url`，为空则 `downloadUrl`；否则原样使用。`PanFile.referer=https://yun.123pan.cn/`。证据：`smali/smali/v4/v.smali:297-406`、`4452-4677`。

---

## 13. 蓝奏与蓝奏优享版

### 13.1 蓝奏（lanzou）

识别 host：`lanzou.com/lanzoui.com/lanzoux.com/lanzouy.com/lanzouj.com/lanzouw.com/lanzn.com`。证据：`smali/smali/v4/v.smali:26-56`。

1. `GET {shareURL}`，header：
   - Chrome 124 UA（`Chrome/124.0 Safari/537.36`）
   - `Accept-Language: zh-CN,zh;q=0.9`
   - `Referer: {shareURL}`
2. 若 HTML 有 `<iframe src=...>`，将相对地址解析到分享页 origin 后再 GET。
3. 从 HTML 提取：
   - file id：`ajaxm?\.php\?file=(\d+)`，或 `file ... (\d{6,})`
   - `sign`：十六进制字符串
   - `websignkey`
   - `kd`（缺省 1）
4. `POST {scheme}://{host}/ajaxm.php?file={fileId}`
   - `Content-Type: application/x-www-form-urlencoded`
   - body：`action=downprocess&websign=&websignkey={encoded}&sign={encoded}&kd={kd}`

Response：

```swift
struct LanzouResponse: Decodable {
    let zt: Int?
    let inf: String?
    let dom: String?
    let url: String?
}
```

`zt==1` 才成功，最终 URL 为 `dom + "/file/" + url`；文件名从 HTML `<title>` 中 `" - "` 前部分提取。未发送账号 Cookie。证据：`smali/smali/v4/v.smali:1145-1567`、`1569-1732`。

### 13.2 蓝奏优享版（ilanzou）

host：`ilanzou.com`。

1. `GET {shareURL}`，Chrome 124 UA + `Referer: {shareURL}`。
2. 从 HTML 提取 `ajaxm?\.php\?file=(\d+)`。
3. `POST {scheme}://{host}/ajaxm.php?file={fileId}`，form：
   `action=downprocess&websign=&websignkey=&sign=&kd=1`。
4. 读 JSON `dom`、`url`，最终 `dom + "/file/" + url`；此分支不检查 `zt`。

优享版 DTO 可复用 `LanzouResponse`（`zt/inf` optional）。未发送账号 Cookie；页面提不到 file id 时 APK 返回需要登录/无法识别页面。证据：`smali/smali/j3/a.smali:300-508`。

---

## 14. 迅雷、139、光年及 `pan_api_*` 的真实边界

### 迅雷

- 分享识别 host：`pan.xunlei.com`；账号登录页：`https://pan.xunlei.com/`。
- 没有对应 token/detail/download endpoint，也没有内置解析分支；落到“还没有内置解析客户端”。

证据：`smali/smali/v4/v.smali:180-192`、`smali/smali/j3/a.smali:1973-1990`。

### 139 和彩云

- 识别 `caiyun.139.com`、`yun.139.com`；登录页 `https://yun.139.com/`。
- 同样没有内置直链 API。

证据：`smali/smali/v4/v.smali:194-212`、`smali/smali/v4/s.smali:74-80`。

### 光年（guangya）

- 账号页：`https://www.guangyapan.com/`。
- `Lv4/v` 的 host 列表没有 guangya；没有解析 endpoint。保存 Cookie 不等于存在 API 实现。

证据：`smali/smali/v4/s.smali:82-104`、`166-178`，对照 `smali/smali/v4/v.smali:214-222`。

### 未接入的第三方解析配置

`galnook.settings` 存在 `pan_api_base`、`pan_api_key`，但全 smali 检索仅在设置读写/状态模型中出现，未见任何 HTTP 请求使用它们；`pan_parse` 只是设置开关。因此不能从 APK 推出第三方光年/网盘解析服务 URL、Authorization 或响应格式。证据：`smali/smali/x4/t.smali:528-569`、`smali/smali/x4/a0.smali:1281-1289`。

---

## 15. 设置键与 iOS 存储映射

| Android 存储/key | 用途 | 是否真正进入请求 |
|---|---|---|
| `galnook.settings["searchgal_base"]` | SearchGal 实例 | 是；空回退默认 |
| `galnook.settings["api_base_host"]` | NextMoe 作品 host | 是；空回退默认 |
| `galnook.settings["api_base"]` | 设置显示状态 | 当前读取，但作品实际 host 用 `api_base_host` |
| `galnook.settings["ymgal_id"]` / `ymgal_secret` | 月幕设置显示 | 否；当前请求仍使用内置常量 |
| `galnook.settings["pan_api_base"]` / `pan_api_key` | 预留解析服务设置 | 未发现请求使用 |
| `galnook.settings["only_searchgal"]` | 禁止内置 SearchGal 补点 | 是 |
| `galnook.pan_accounts[{siteId}]` | 网盘完整 Cookie | 按各网盘流程使用 |
| `galnook.pan_accounts["pan123.token"]` | 123 authorToken | 是，Bearer |

设置读取证据：`smali/smali/x4/t.smali:398-690`；设置文件来源：`smali/smali/v4/q.smali:11-50`。

---

## 16. 公开接口实测记录（本次会话）

| 接口 | 实测结果 | 仅用于确认的事实 |
|---|---|---|
| NextMoe `/v2/catalog/works` | HTTP 200 | 顶层 `$schema/object/items`；item 含 id/display_name/localized/cover/ratings 等 |
| NextMoe 详情/角色二次验证 | TLS handshake timeout | 不把它写成成功；上述详情契约完全来自 smali |
| VNDB `/kana/vn` 搜索 | HTTP 200 | 顶层 `more/results`；item 含所请求 fields |
| Ymgal `/oauth/token` | HTTP 200 | 返回 access_token/scope/token_type/expires_in；未记录 token 值 |
| Ymgal `/open/archive/search-game` | HTTP 200 | `success/code/data`；data 含 result/total/hasNext/pageNum/pageSize |
| CnGal `GetAllEntriesIdName` | HTTP 200 | 顶层数组，元素形如 `{"id":1,"name":"茸雪"}` |
| CnGal `GetEntryView/1` | HTTP 200 | id/name/anotherName/briefIntroduction 类型符合 DTO |
| SearchGal `/gal` | HTTP 200，`text/event-stream` | 本次有 total/progress/result；result 为 name/color/tags/items，item 为 name/url |
| GitHub `GalNook/releases/latest` | HTTP 200 | 含 tag_name/name/body/html_url/published_at/assets；APK asset 有 browser_download_url |
| 各网盘分享解析 | 未执行 | 未使用有效分享样本和用户 Cookie/token，不宣称在线成功 |

---

## 17. iOS 落地检查清单

1. NextMoe/VNDB/CnGal/Ymgal/SearchGal/GitHub 可直接按上述 DTO 实现；Ymgal token 必须在过期前 60 秒刷新。
2. SearchGal 用流式逐行 parser，不要等整个 body 组成单一 JSON。
3. 所有 snake_case 与大小写异常字段逐一核对 `CodingKeys`，尤其 123、115、GitHub 的 URL 字段。
4. 网盘 ID/大小用 `LooseString` 或自定义解码；不要将 Android 的 `optString` 错当成“服务端一定返回 string”。
5. 夸克/UC 保存并延续 `__pugs`，登录检查另看 `__pus/__puus`；遇到 23026/31001 进入用户 Cookie 流程。
6. 百度先 verify 得 randsk，再以 BDCLND 重取页面参数；账号 Cookie 与 BDCLND 是不同凭证状态。
7. 115 无 Cookie 不请求；123 无 authorToken 不请求；123 签名保留硬编码 `|web|3|` 和 CRC32 不补零行为。
8. 蓝奏必须从实时 HTML 提取参数；不要硬编码 sign/websignkey/file id。
9. 最终文件 GET 只带桌面 UA、PanFile.referer 和可选 Range；当前 helper 不携带 Cookie。
10. 迅雷/139/光年保持浏览器打开能力，不伪造不存在的直链契约。
