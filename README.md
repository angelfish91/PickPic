# PickPic

PickPic 是一个原生 SwiftUI 照片应用，用来重新理解本地照片库：它可以按时间和内容整理照片、生成回忆、过滤文档/二维码等非照片内容、支持自然语言语义搜索，并把精选照片生成带转场和背景音乐的回忆视频。

## 功能亮点

- 照片图库浏览：基于 `Photos` 读取本地照片库，使用缩略图管线和预热机制提升滚动体验。
- 回忆与事件：按时间和照片内容组织照片，生成可浏览的回忆/事件集合。
- 智能过滤：通过 `Vision` 做文字识别、条码检测、图像分类和特征提取，识别文档、菜单、截图、二维码等非照片内容。
- 语义搜索：使用多语言 SigLIP Core ML 模型，为照片建立向量索引，支持用自然语言搜索照片。
- 回忆视频：通过 `AVFoundation` 和 `CoreImage` 生成竖屏 MP4，包含转场、Live Photo 帧提取和合成音乐。
- 后台索引：使用 `BackgroundTasks` 在合适时机继续补齐照片理解和语义索引。

## 技术栈

- Swift 5
- SwiftUI
- Photos
- Vision
- Core ML
- AVFoundation
- CoreImage
- BackgroundTasks
- SQLite3

项目最低部署版本为 inpx skills add nexu-io/open-design@frontend-designOS 18.0，支持 iPhone、iPad，并开启了 Mac Catalyst。

## 项目结构

```text
PickPic/
  App/                  App 入口与全局状态注入
  Design/               主题、品牌标识和通用视觉样式
  Features/             SwiftUI 页面与交互功能
  Models/               照片库状态、索引、分析、视频生成等核心逻辑
  Assets.xcassets/      图标、品牌图和颜色资源
Tools/
  convert_siglip.py     SigLIP 到 Core ML 的转换脚本
LocalModels/            本地模型输出目录，已被 gitignore 忽略
```

关键文件：

- `PickPic/App/PickPicApp.swift`：应用入口，创建并注入 `PhotoLibraryStore`。
- `PickPic/Models/PhotoLibraryStore.swift`：照片权限、加载、缓存、事件、视觉分析、语义索引和后台任务的核心状态管理。
- `PickPic/Models/SemanticEmbeddingService.swift`：SigLIP 模型加载、文本/图像 embedding、SQLite 语义索引和搜索。
- `PickPic/Models/VisualAnalysisService.swift`：Vision 分析与非照片内容判断。
- `PickPic/Models/MemoryVideoGenerator.swift`：回忆视频生成与保存。
- `PickPic/Features/RootView.swift`：主界面 tab、搜索入口和启动准备遮罩。

## 运行项目

使用 Xcode 打开：

```sh
open PickPic.xcodeproj
```

查看 scheme：

```sh
xcodebuild -list -project PickPic.xcodeproj
```

命令行构建：

```sh
xcodebuild -project PickPic.xcodeproj \
  -scheme PickPic \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

当前仓库没有单独的测试 target。修改代码后建议至少跑一次 Xcode 构建；如果改动涉及照片权限、语义索引、视频生成或后台任务，还需要在模拟器或真机上手动验证相关流程。

## 语义模型资源

语义搜索依赖 SigLIP Core ML 资源。运行时会查找：

- `SigLIPImageEncoder.mlmodelc`
- `SigLIPTextEncoder.mlmodelc`
- `SigLIPTokenizer.bundle/tokenizer.json`

仓库中跟踪了 tokenizer 相关资源，但 `LocalModels/` 和部分模型包被忽略，避免把大型本地模型产物直接提交到 Git。需要重新生成模型时，可以参考：

```sh
python Tools/convert_siglip.py
```

该脚本会下载 `google/siglip-base-patch16-256-multilingual`，依赖 `coremltools`、`torch`、`transformers` 等 Python 包，并把产物写入 `LocalModels/SigLIPMultilingual`。在把模型资源纳入 app bundle 或发布前，请先确认体积、授权和分发策略。

## 隐私与权限

PickPic 主要处理用户本地照片库。`PickPic-Info.plist` 中包含：

- `NSPhotoLibraryUsageDescription`
- `NSPhotoLibraryAddUsageDescription`
- `BGTaskSchedulerPermittedIdentifiers`
- `UIBackgroundModes`

新增照片相关能力时，请同步检查权限文案、后台任务标识和实际代码中的使用方式。

## 给协作者的提示

项目根目录包含 `AGENTS.md`，里面整理了给 Codex/自动化协作者使用的项目约定、构建命令、资源说明和注意事项。开始较大改动前，建议先阅读它。
