# 番茄小说 Flutter 客户端

基于 [Wenku8_Flutter](https://github.com/mikufoxxx/Wenku8_Flutter) 改造的番茄小说第三方客户端。保留原项目的阅读器、视觉语言与听书管线，把在线内容层整体换成番茄小说。

> 非官方项目，与番茄小说及其运营方无关。本项目不提供、不分发任何书籍内容。

## 现在的状态

在线层已经接通。阅读器、听书、书架、缓存都在原项目上原样保留，换掉的是「数据从哪来」。

| 模块 | 状态 |
| --- | --- |
| 阅读器（横向 / 纵向 / 沉浸 / 仿真翻页） | 保留，可用 |
| 听书（系统 TTS / edge-tts / 自定义接口 / 0.5–3× 倍速 / 段落跟随 / 睡眠定时 / 后台与锁屏控制） | 保留，可用 |
| 本地书导入（EPUB / MOBI / PDF / TXT / 压缩包） | 保留；原生批量导入是桩 |
| 书架、阅读统计、云备份、主题与字体 | 保留，可用 |
| 番茄正文抓取 | **已通**，整本可缓存，不受网页版 10 章限制 |
| 书名搜索 | **已通**，走 App 网关，一次 10~20 条 |
| 题材分类 | **已通**，13 个题材大类 + 落地页筛选维度 |
| 番茄账号登录 | **已做**，App 内原生 WebView 走番茄自己的登录页 |
| 书架云同步 | 接口已接（`/reading/bookapi/bookshelf/list/v1/`），等真账号实测字段 |
| 段评 / 书评 / 书荒广场 | 界面在，数据源是桩 |
| 阅读时长同步 | 未开始 |

## 正文为什么能绕开 10 章

网页版 `fanqienovel.com/reader/{itemId}` 从第 11 章起 `isChapterLock=true`，只回一句开头加「扫码下载 APP 免费读」；`/api/reader/full` 回 `200` 但 body 是 0 字节。App 网关那条路能出全文，代价是要带签名。

签名是纯算法，不依赖 `.so`，实现全在 `lib/fanqie_sign.dart`（约 700 行 Dart，AES / Simon / SM3 都是手写的，只借了 `package:crypto` 的 md5）：

- **`x-argus`** — 自定义 protobuf 组包 → PKCS7 → Simon 64/128 逐块 → 魔数改写与反转 → 追加 `ao` → AES-128-CBC → base64。
- **`x-ladon`** — `"{ts}-{license_id}-{aid}"` 走 34 轮 ARX，输出 `base64(rnd4 + 密文)`。
- **`x-khronos` / `x-ss-req-ticket`** — 时间戳与毫秒时间戳。POST 另加 `x-ss-stub = md5(body)`。
- `x-gorgon` 现在不需要（上游已判它失效），网上那些 X-Gorgon 0404 的 JS 实现可以不管。

拿到正文后还要解一层：先 `POST /reading/crypt/registerkey` 换 `v1_key`（用固定主密钥 `ac25c67ddd8f38c1b37a2348828e222e` 解），再 `base64 → 前 16 字节 iv → AES-128-CBC → unpad`，`compress_status > 0` 时结果是 gzip。

两个坑，踩过就不要再踩：

- `device_id` 必须是 19 位十进制且小于 2^63。`'7' + 18 位随机` 稳；`9` 开头或 20 位会被判 `verify fail`。
- `registerkey` 的 `iid` 只能填 `"0"`。填随机设备号同样 `verify fail`。

## 用到的接口

全部实测 200，`host` 默认 `reading.snssdk.com`。

| 用途 | 路径 | 备注 |
| --- | --- | --- |
| 正文 | `/reading/reader/full/v/` | 必须带 `device_type=Honor10`、`os_version=0`、`version_code=66.9` |
| 搜索 | `/reading/bookapi/search/page/v/` | 书对象在 `data[i].book_data[0]`，空的那格是广告位 |
| 分类落地 | `/reading/bookapi/new_category/landing/v/` | 书目在 `data.book_info`，筛选维度在 `data.rule` |
| 题材大类 | `/reading/bookapi/category/list/v/` | 只有一层，13 个 |
| 书架 | `/reading/bookapi/bookshelf/list/v1/` | 换 `api5-normal-sinfonlineb`，版本号成套用 73932 / 7.3.9.32 |

筛选维度的取值（`data.rule` 里也是这份）：

- `sort_by` — 综合 `0` / 热门 `24` / 最新 `76` / 评分 `12`
- `word_type` — 全部 `0` / 100 万字以下 `1` / 100–300 万 `2` / 300 万以上 `3`
- `book_status` — 全部 `2` / 完结 `0` / 连载中 `1` / 今日更新 `3`

封面拿到的是带签名、几小时就过期的 `p3-reading-sign.fqnovelpic.com/novel-pic/<hash>~tplv-...`。把 `~` 之后砍掉、host 换成 `p6-novel.byteimg.com/origin`，同一张图不会过期。

## 登录

番茄的手机号登录带 bdturing 滑块，客户端自己跑不完；`sessionid` 又是 HttpOnly，网页里的 JavaScript 读不到。

所以走原生：`FanqieLoginPlugin.kt` 开一个 `FanqieLoginActivity`，把 `fanqienovel.com` 装进 WebView，用户登完点「完成」，由 `android.webkit.CookieManager.getCookie()` 把 HttpOnly 的 cookie 一起读回来（Flutter 官方的 `webview_flutter` 只有 set / clear，拿不到 cookie，所以这里没引它）。

登录态是否真的算数，只认 `https://fanqienovel.com/api/user/info/v2` 回 `code == 0` 且 `data` 非空。注意 App 版 `/reading/user/info/v/` 未登录时会返回一个匿名用户（`用户712345678`），**不能**用来判登录。

也保留了老路径：账号栏直接粘 Cookie 串也能导入。

## 改造点在哪

原项目的在线能力全部走注入，不写死在页面里：

- **书目与正文** — `lib/app_repository.dart` 的 `openApplicationLibrary(remote:)` 决定用哪个仓库，番茄实现是 `lib/fanqie_repository.dart`。接口定义在 `lib/catalog.dart` 的 `abstract class NovelRepository`。
- **传输层** — `lib/fanqie_api.dart`（接口、解析、解密）与 `lib/fanqie_sign.dart`（签名）。
- **id 映射** — `lib/fanqie_ids.dart`。番茄的 bookId 有 19 位，直接当 `Novel.id` 会被上游的 `isLocalBook` 当成未导入的本地书，所以映射到 `0x40000000` 起的区间。
- **正文字体** — `lib/fanqie_font.dart` 的 362 条 PUA 映射。App 网关返回的是干净正文，这层只对网页版残留的私用区字符生效。
- **账号与会话** — `lib/fanqie_account.dart` 与 `lib/fanqie_login.dart`。
- **段评 / 书评** — `lib/wenku_reviews.dart` 的 `ReviewFeed(reader:)`，换掉 `typedef ReviewPageReader` 即可。

## 构建

构建走 GitHub Actions：

```
Actions → Build APK → Run workflow
```

产物在 run 页面的 `logs-and-apk` artifact 里（含 `analyze.log` 与 `build.log`，构建失败也能拿到日志）。工作流文件：`.github/workflows/build.yml`。

本地构建需要 Flutter 3.50+ / Dart 3.11+ / JDK 21 / Gradle 9.3.1 / AGP 9.1.1。

## 关于源码完整性

上游公开的快照里缺 19 个模块（自定义 TTS、局域网续读、本地批量扫描、桌面小组件等）。本仓库为它们补了**可编译的占位实现**：类型和签名按真实调用点还原，行为一律是空转或返回空结果。

## 许可

继承上游，GPL-3.0。见 `LICENSE` 与 `assets/licenses/GPL-3.0.txt`。
