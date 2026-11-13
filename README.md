# 番茄小说 Flutter 客户端

基于 [Wenku8_Flutter](https://github.com/mikufoxxx/Wenku8_Flutter) 改造的番茄小说第三方客户端。保留原项目的阅读器、视觉语言与听书管线，把在线内容层整体换成番茄小说。

> 非官方项目，与番茄小说及其运营方无关。本项目不提供、不分发任何书籍内容。

## 现在的状态

**在线层还没接。** 这个仓库目前是「完整 UI + 空数据源」：所有界面、阅读器、听书、本地导入都能跑，但凡是涉及番茄网络请求的地方，返回的都是空结果或「此构建未包含」的提示。

| 模块 | 状态 |
| --- | --- |
| 阅读器（横向 / 纵向 / 沉浸 / 仿真翻页） | 保留，可用 |
| 听书（系统 TTS / edge-tts / 自定义接口 / 0.5–3× 倍速 / 段落跟随 / 睡眠定时 / 后台与锁屏控制） | 保留，可用 |
| 本地书导入（EPUB / MOBI / PDF / TXT / 压缩包） | 保留；原生批量导入是桩 |
| 书架、阅读统计、云备份、主题与字体 | 保留，可用 |
| 番茄账号登录 | 未开始 |
| 番茄在线书库 / 搜索 / 分类 | 未开始 |
| 番茄正文抓取 | 未开始 |
| 段评 / 书评 / 书荒广场 | 界面在，数据源是桩 |
| 阅读时长同步 | 未开始 |

## 改造点在哪

原项目的在线能力全部走注入，不写死在页面里。要换源，只需要替换这几处：

- **书目与正文** — `lib/app_repository.dart` 的 `openApplicationLibrary(remote:)`，把 `LegacyWenkuRepository` 换成番茄实现即可，阅读器、书架、缓存都不用动。接口定义在 `lib/catalog.dart:280` 的 `abstract class NovelRepository`。
- **段评 / 书评** — `lib/wenku_reviews.dart` 的 `ReviewFeed(reader:)`，`typedef ReviewPageReader` 换成番茄的评论接口。
- **账号与会话** — `lib/wenku_account.dart` 的 `WenkuAccount`，目前只有数据结构，没有任何请求逻辑。
- **听书** — `lib/listening/` 整层与内容源无关，接上正文就能直接朗读。

## 构建

本机没有 Flutter 工具链，构建走 GitHub Actions：

```
Actions → Build APK → Run workflow
```

产物在 run 页面的 `logs-and-apk` artifact 里。工作流文件：`.github/workflows/build.yml`。

本地构建需要 Flutter 3.50+ / Dart 3.11+ / JDK 21 / Gradle 9.3.1 / AGP 9.1.1。

## 关于源码完整性

上游公开的快照里缺 19 个模块（自定义 TTS、局域网续读、本地批量扫描、桌面小组件等）。本仓库为它们补了**可编译的占位实现**：类型和签名按真实调用点还原，行为一律是空转或返回空结果。

也就是说：**这些功能在界面上看得到，点下去不会真的工作**。等在线层接通后，再逐块换回真实实现。

## 许可

继承上游，GPL-3.0。见 `LICENSE` 与 `assets/licenses/GPL-3.0.txt`。
