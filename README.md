# DouDuo

一个**适配 iPhone Duo（折叠屏）/ iPad / 横屏的第三方抖音客户端**，界面和播放全部原生（SwiftUI + AVPlayer，VLC 兜底）。

官方抖音 App 在折叠屏内屏、iPad 上不适配，网页版又总是跳 App，所以有了它。

<p align="center">
  <img src="docs/screenshots/feed.jpg" width="200">
  <img src="docs/screenshots/search.jpg" width="200">
  <img src="docs/screenshots/comments.jpg" width="200">
  <img src="docs/screenshots/live.jpg" width="200">
</p>

> ⚠️ 非官方项目，仅供个人学习交流，与抖音 / 北京微播视界科技有限公司无关。详见文末[声明](#声明)。

## 功能

**看视频**
- 推荐 / 关注 / 直播，顶部一排切换；整页上下滑
- **秒开**：打开 App 先播上次已缓存的视频，连接抖音在后台进行
- **预缓存**：边看边在后台把后面 50 条完整下载到本地，下滑不等加载（菜单可选 关 / 20 / 50 / 100 条，总量超 2GB 自动清理）
- 屏幕任意位置**横滑快进 / 快退**（带预览缩略图），双击点赞，长按 2 倍速（长按后下滑可锁定，单击取消），单击暂停
- **自动铺满**：竖屏看竖屏铺满宽度、横屏看横屏铺满高度；方向不一致时保持完整画面（菜单可关）
- 退到后台立即停声

**互动**（需在 App 内登录抖音，见下文）
- 点赞、收藏，同步到你的抖音账号
- 评论：查看、展开楼中楼、**发评论 / 回复**
- **视频弹幕**：显示 + 发送（菜单可关）
- 直播：原生播放（VLC 解 HEVC 流）、**直播间聊天显示 + 发言**
- 保存视频 / 图集到相册

**我的**
- 搜索（联想词、搜索历史）
- 喜欢 / 收藏 / 观看历史 / 稍后再看，点进去接着上下滑
- 作者资料卡

## 安装

iOS / iPadOS **17.0 及以上**。DouDuo 不在 App Store（第三方客户端过不了审核），需要**自己签名安装**。以下方式任选一种：

先到 [Releases](../../releases/latest) 下载最新的 `DouDuo-x.y.z-unsigned.ipa`。

### 方式一：爱思助手（Windows / Mac，最简单）

1. 电脑安装 [爱思助手](https://www.i4.cn)，用数据线连接 iPhone，手机上点「信任此电脑」
2. 爱思助手 →「工具箱」→「IPA 签名」
3. 「添加 IPA 文件」选择下载的 `DouDuo-x.y.z-unsigned.ipa`
4. 「使用 Apple ID 签名」→「添加 Apple ID」，输入你的 Apple ID 和密码（建议用一个**小号**，不要用主力账号）
5. 勾选 IPA 和 Apple ID →「开始签名」，完成后点「安装」
6. 手机：**设置 → 通用 → VPN 与设备管理** → 找到你的 Apple ID → 「信任」
7. iOS 16 以上首次打开还要开 **设置 → 隐私与安全性 → 开发者模式**（打开后会重启）

> 免费 Apple ID 签名的 App **7 天后过期**（打开闪退），重复第 2～5 步重新签名即可，数据不会丢。

### 方式二：Sideloadly（Windows / Mac）

1. 安装 [Sideloadly](https://sideloadly.io)（Windows 还需要 iTunes 和 iCloud 的**官网桌面版**，不是微软商店版）
2. 连接 iPhone，把 IPA 拖进 Sideloadly 窗口
3. 「Apple account」填你的 Apple ID，点「Start」，按提示输入密码 / 双重认证验证码
4. 安装后同方式一的第 6、7 步：信任开发者、打开开发者模式

> 同样 7 天过期。Sideloadly 支持开启「Automatic refresh」，电脑开着、手机在同一 Wi‑Fi 时会自动续签。

### 方式三：手机上直接签（SideStore / AltStore / 第三方签名 App）

- **[SideStore](https://sidestore.io)**：首次需要电脑配置一次，之后在手机上就能安装、自动续签，不用再连电脑。装好后在 SideStore 里点「+」选择 IPA 即可
- **[AltStore](https://altstore.io)**：需要电脑上常驻 AltServer，同一 Wi‑Fi 下自动续签
- **自有证书的签名 App**（如 ESign、轻松签、全能签等）：如果你**自己有** p12 证书 + 描述文件（个人 / 企业开发者账号导出），导入证书后选择 IPA 签名安装
- **TrollStore（巨魔）**：签一次永久有效，但只支持部分系统版本（以 TrollStore 官方说明为准），较新的 iOS 用不了

> ⚠️ 不要使用网上流传的「免费证书」「共享企业证书」：这类证书随时会被苹果吊销（掉签打不开），也存在隐私风险。

### 方式四：自己编译（有 Mac）

需要 macOS + Xcode 26 以上、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
git clone https://github.com/81199000/DouDuo.git
cd DouDuo
brew install xcodegen
./scripts/fetch-vlckit.sh      # 下载 VLC 播放内核（约 1GB，不在仓库里）
xcodegen generate
open DouDuo.xcodeproj
```

在 Xcode 里：
1. 选中 `DouDuo` target →「Signing & Capabilities」→ Team 选你自己的 Apple ID（Xcode → Settings → Accounts 先登录）
2. 把 Bundle Identifier 改成你自己的（比如 `com.yourname.douduo`），免费账号不能用别人注册过的 ID
3. 连上 iPhone，选中设备，点 ▶︎ 运行
4. 手机上信任开发者 + 打开开发者模式（同方式一的第 6、7 步）

免费账号同样 7 天有效；付费开发者账号（99 美元 / 年）签的一年有效。

只想要未签名 IPA：`./release.sh`（产物在 `build/`，有 `gh` 登录时会顺带上传 Release）。

## 首次使用：登录抖音

点右上角「我的」→「网页版 / 登录」，在抖音网页里用**验证码或密码**登录。登录后：

- 推荐流会按你的账号个性化
- 点赞、收藏、评论、弹幕会同步到你的抖音账号
- 「我的」里能看到喜欢、收藏、观看历史

不登录也能看推荐、搜索、直播。登录信息只保存在手机本地，不经过任何第三方服务器。

## 常见问题

- **打开就闪退**：签名过期了（免费 Apple ID 7 天），重新签名安装即可。
- **提示「抖音拦截了请求」/ 一直加载**：点菜单 →「网页版 / 登录」，在网页里刷一下（必要时过一下滑块验证），返回后会自动重试。
- **视频黑屏或卡住**：App 会自动重试，并切换到 VLC 内核兜底；仍不行就下滑到下一条。
- **占用空间大**：菜单 →「预缓存视频」调小或关闭，或者点「清除视频缓存」。用流量刷时建议关掉预缓存。
- **搜索结果只有一页**：抖音网页接口只返回第一页，目前没有办法翻页。

## 原理

没有逆向抖音 App，也不需要任何密钥：

- App 里挂着一个**看不见的抖音网页**（电脑版 UA）。所有接口请求都在这个页面里发出，由抖音网页自己的安全 SDK 自动补签名（`a_bogus` 等），所以签名算法跟着官方更新走。
- 视频地址用接口返回的 `/aweme/v1/play/`（302 到 CDN mp4）。CDN 要求带浏览器 UA + Referer，否则部分节点 403。
- 普通视频用 `AVPlayer`；起不来时自动切 VLC。直播流是 HEVC + MPEG‑TS，AVPlayer 只能出声音，所以直播一律用 VLC。
- 直播间聊天：后台打开一个隐藏的直播间网页，读它渲染出来的聊天列表，不碰 WebSocket 协议。
- 登录态和「网页版」共用 `WKWebsiteDataStore.default()`，只存在本机。

主要接口：

| 功能 | 接口 |
| --- | --- |
| 推荐 | `POST /aweme/v2/web/module/feed/` |
| 关注 | `/aweme/v1/web/follow/feed/` |
| 搜索 / 联想 | `/aweme/v1/web/search/item/`、`/search/sug/` |
| 评论 / 楼中楼 / 发评论 | `/comment/list/`、`/aweme/v2/web/comment/list/reply/`、`POST /comment/publish` |
| 弹幕 / 发弹幕 | `/danmaku/get_v2/`、`POST /danmaku/post_v2/` |
| 点赞 / 收藏 | `POST /commit/item/digg/`、`POST /commit/item/collect/` |
| 喜欢 / 收藏 / 历史 / 稍后再看 | `/aweme/favorite/`、`POST /aweme/listcollection/`、`/history/read/`、`/watchlater/list/` |
| 直播 | `live.douyin.com/webcast/feed/` |

## 项目结构

```
DouDuo/
  DouDuoApp.swift          入口、退后台停声
  DouyinFeedView.swift     推荐 / 直播主界面、签名代理（DouyinBridge）、评论
  DouyinExtras.swift       搜索、我的、关注、作者页、弹幕、保存、发评论 / 弹幕
  DouyinLiveChat.swift     直播间聊天（显示 + 发言）
  DouyinVideoCache.swift   本地视频预缓存 + 秒开
  ShortVideoPlayer.swift   播放器（手势、进度、VLC 兜底、弹幕层）
  VLCPlayerBridge.swift    VLC 封装
  DouyinWebView.swift      网页版容器（登录）
Vendor/VLCKit/             VLC 本地 Swift Package（二进制用脚本下载）
project.yml                XcodeGen 工程定义
```

## 已知限制

- 搜索只有第一页；作者的作品列表要点「查看全部作品」去网页版看（网页接口签名受限）
- 抖音风控时可能要去「网页版」过一下验证
- 抖音网页接口改版时，需要跟着更新

欢迎提 Issue / PR。

## 声明

- 本项目是个人学习用的**非官方**客户端，与北京微播视界科技有限公司 / 抖音没有任何关系，也未获得其授权。
- 所有视频、图片、评论等内容的版权归原作者与抖音所有，本项目不存储、不分发任何内容。
- 请遵守《抖音用户服务协议》，**仅供个人学习使用，禁止用于商业用途、批量抓取、刷量等行为**。
- 因使用本项目产生的任何后果由使用者自行承担。
- 如有侵权请提 Issue，会第一时间处理。

## License

[MIT](LICENSE)
