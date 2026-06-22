# PickPic 当前跨模态检索算法架构

本文档说明 PickPic 当前版本的跨模态照片检索架构，覆盖模型资源、图片索引、文本查询、相似度计算、结果过滤、缓存持久化和后台调度。本文描述的是仓库中的现有实现，而不是规划中的未来方案。

## 1. 总体架构

PickPic 的跨模态检索采用本地端侧的双塔语义嵌入架构：

- 图片侧：将 `PHAsset` 对应的照片缩放为 256 x 256 图像，送入 Core ML 版 SigLIP image encoder，得到图片向量。
- 文本侧：将用户输入的自然语言描述切分为 tokenizer token，送入 Core ML 版 SigLIP text encoder，得到文本向量。
- 检索侧：在同一个嵌入空间内，对文本向量和本地图片向量做点积相似度计算，然后按分数降序排序。
- 存储侧：图片向量以 `Float` 数组的二进制 BLOB 形式存入应用支持目录下的 SQLite 数据库。

核心代码位置：

- `PickPic/Models/SemanticEmbeddingService.swift`：跨模态模型加载、图片索引、文本查询、向量库读写。
- `PickPic/Models/PhotoLibraryStore.swift`：照片库读取、视觉过滤、索引调度、搜索结果阈值过滤和 UI 状态。
- `PickPic/Models/SigLIPTokenizer.swift`：SigLIP 文本 tokenizer 的本地 Swift 实现。
- `PickPic/Models/VisualAnalysisService.swift`：OCR、条码、分类和 Vision feature print，用于过滤非照片内容和辅助回忆聚类。
- `Tools/convert_siglip.py`：将 Hugging Face SigLIP 模型转换为 Core ML 图片/文本 encoder 和 tokenizer 资源。

当前实现不是向量数据库近似最近邻检索，而是内存中的全量线性扫描。原因是端侧照片量级通常可控，线性扫描实现简单、可解释，且避免引入额外 ANN 索引维护成本。

## 2. 模型与资源

当前语义模型标识为：

```text
google/siglip-base-patch16-256-multilingual
```

应用运行时要求 bundle 中存在以下资源：

```text
SigLIPImageEncoder.mlmodelc
SigLIPTextEncoder.mlmodelc
SigLIPTokenizer.bundle/tokenizer.json
```

`SemanticEmbeddingService.prepare()` 负责懒加载这些资源。加载成功后，服务状态变为“多语言 SigLIP 已就绪”。如果资源不存在，状态会变为“未找到语义模型资源”，搜索和索引会返回空结果或失败。

Core ML 推理配置使用：

```swift
configuration.computeUnits = .cpuAndNeuralEngine
```

这样做是为了减少前台 UI 动画和 GPU 的竞争。模型转换脚本 `Tools/convert_siglip.py` 会把原始 SigLIP 拆成两个 encoder：

- `ImageEncoder`：输入图片，输出 `image_embedding`。
- `TextEncoder`：输入 `input_ids`，输出 `text_embedding`。

转换脚本中两个 encoder 都会调用 `functional.normalize(..., dim=-1)`，因此当前向量预期是 L2 归一化后的向量。运行时相似度使用点积；在归一化前提下，点积等价于余弦相似度。

## 3. 文本编码算法

文本查询由 `SigLIPTokenizer` 编码，流程如下：

1. 文本归一化：
   - 使用 compatibility precomposition。
   - 转小写。
   - 移除一组英文标点。
   - 合并连续空白。
   - 使用 SentencePiece 风格的 `▁` 表示词边界。
2. 动态规划分词：
   - tokenizer 文件保存了词表 token 和 score。
   - 实现按首字符分组，并优先尝试更长 piece。
   - 动态规划选择累计 score 最高的 token 序列。
   - 无法匹配的字符使用 unknown token，并施加较大的 score 惩罚。
3. 输入构造：
   - `tokenizer.encode(text)` 后追加 `eosTokenID`。
   - 最大长度截断为 64。
   - 不足 64 的位置填充 token id `1`。
   - 构造形状为 `[1, 64]` 的 `MLMultiArray(.int32)`，以 `input_ids` 输入文本模型。

文本 embedding 会以原始查询字符串为 key 缓存在内存中。缓存最多保留 32 条；超过后清空，避免长期占用内存。

## 4. 图片索引算法

图片索引入口是：

```swift
SemanticEmbeddingService.index(asset:quality:allowNetworkAccess:)
```

每张照片的索引流程如下：

1. 确保模型资源已经加载。
2. 判断是否需要重建索引：
   - 如果资产没有已有向量，需要索引。
   - 如果 `modificationDate` 或 `creationDate` 对应的时间戳变化，需要重建。
   - 如果已有索引质量低于本次要求，需要升级索引。
3. 通过 `PHImageManager.requestImage` 取 256 x 256 图片。
4. 将 `UIImage` 转为 Core ML image feature，输入 `SigLIPImageEncoder`。
5. 从模型输出读取 `image_embedding`，转换为 `[Float]`。
6. 以 `asset.localIdentifier` 为 key，写入内存字典和 SQLite。

索引质量分为两档：

```swift
enum SemanticIndexQuality: Int {
    case thumbnail = 0
    case refined = 1
}
```

`thumbnail` 用于快速覆盖照片库，让搜索尽快可用。它使用 Photos 的 `.fastFormat` 和 `.fast` resize，不允许下载 iCloud 原图。

`refined` 用于后台精细化。它使用 `.highQualityFormat` 和 `.exact` resize，并可在设置允许时下载 iCloud 照片。对于 refined 请求，代码会忽略 degraded 回调，等待非 degraded 图片结果。

## 5. 两阶段索引流水线

`PhotoLibraryStore.scanAllAssets()` 负责照片库级别的索引编排。当前流水线分为两个阶段。

### 5.1 快速索引阶段

快速阶段目标是尽快建立可搜索能力：

1. 从 Photos 获取图片资产，并先做基础过滤：
   - 隐藏照片排除。
   - 没有创建时间排除。
   - 宽高小于 480 的图片排除。
   - screenshot subtype 排除。
2. 加载或更新视觉分析结果。
3. 使用 `SemanticEmbeddingService.assetIDsRequiringIndex(..., quality: .thumbnail)` 找出缺失、过期或质量不足的语义索引。
4. 对视觉分析判定为文档的资产不做语义索引。
5. 以非常小的 batch 逐张处理，并在每轮之间 sleep 约 80ms。
6. 周期性更新 UI 进度、持久化视觉缓存和刷新状态。

快速阶段完成后，已有 thumbnail 向量的照片即可参与搜索。

### 5.2 精细索引阶段

快速阶段后，系统会对当前可见照片继续做 refined 索引：

1. 只处理没有 refined 向量或索引已过期的照片。
2. 如果设置为仅 Wi-Fi 下载 iCloud 照片，则在非 Wi-Fi 条件下暂停网络下载。
3. 使用高质量 Photos 请求补齐或替换 thumbnail 向量。
4. 更新 refined 计数和状态。

这种设计的权衡是：首轮搜索响应更早，但早期结果可能基于缩略图语义；后台精细化完成后，排序质量会更稳定。

## 6. 非照片内容过滤

PickPic 不会把所有图片都直接纳入语义搜索。`VisualAnalysisService` 会先对候选资产做轻量视觉分析：

- `VNRecognizeTextRequest`：估计文本区域面积和文本块数量。
- `VNDetectBarcodesRequest`：检测条码或二维码。
- `VNClassifyImageRequest`：识别 document、menu、poster、screenshot、text、web site 等非照片类别。
- `VNGenerateImageFeaturePrintRequest`：生成 Vision feature print，主要用于回忆事件聚类，不直接用于语义搜索排序。

`PhotoVisualAnalysis.isLikelyDocument` 判定为 true 时，该资产会从可见照片和语义索引候选中移除。判定条件包括：

- 包含条码。
- 分类命中非照片标签且置信度不低于 0.3。
- 文本块不少于 3 且文本面积比例不低于 0.16。
- 文本面积比例不低于 0.28。

这层过滤的作用是降低文档、菜单、网页截图、二维码等内容对“回忆照片”搜索结果的污染。

## 7. 向量库与持久化

语义索引存储在应用支持目录：

```text
Application Support/PickPic/siglip-multilingual-index-v2.sqlite
```

SQLite 表结构包括：

```sql
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS embeddings (
    asset_id TEXT PRIMARY KEY,
    modified_at REAL,
    quality INTEGER NOT NULL DEFAULT 1,
    vector BLOB NOT NULL
) WITHOUT ROWID;
```

`metadata` 保存索引版本和模型标识。如果版本或模型不匹配，现有 embedding 会被清空，避免不同模型空间的向量混用。

`embeddings` 保存：

- `asset_id`：Photos 本地标识。
- `modified_at`：资产修改时间或创建时间，用于判断索引是否过期。
- `quality`：thumbnail 或 refined。
- `vector`：`[Float]` 的原始内存字节。

数据库性能设置：

```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA temp_store=MEMORY;
```

写入采用事务批处理。`SemanticEmbeddingService` 每 upsert 100 条左右主动 commit，结束时通过 `flush()` 提交剩余写入。

旧版 JSON 索引 `siglip-multilingual-index-v1.json` 会在启动时迁移到 SQLite；迁移完成后旧文件会重命名为 `.migrated.json`。

## 8. 在线查询流程

用户搜索入口在 `SearchView.performSearch()`，核心调用链为：

```text
SearchView.performSearch()
  -> PhotoLibraryStore.search(query, progress:)
    -> SemanticEmbeddingService.search(query, progress:)
```

`SemanticEmbeddingService.search()` 的执行阶段：

1. `understanding`：文本 query 编码为文本向量。
2. `comparing`：遍历内存中的全部图片向量，计算点积相似度。
3. `ranking`：按 score 降序排序。

相似度计算使用 Accelerate：

```swift
vDSP.dot(lhs, rhs)
```

当前没有 ANN、倒排索引或服务端检索；所有候选都在端侧内存中逐一比较。

`PhotoLibraryStore.search()` 会在排序后进一步做结果截断。阈值为：

```swift
similarityThreshold = max(minimumSearchSimilarity, bestScore - maximumScoreDrop)
```

当前常量：

```swift
minimumSearchSimilarity = 0.08
maximumScoreDrop = 0.055
```

也就是说，系统会保留不低于绝对下限 0.08，且距离最高分不超过 0.055 的候选。这样可以避免低相关结果被展示，同时让不同查询的返回数量随最佳匹配强度自适应变化。

用户在详情页标记“不相关”后，资产 id 会按归一化 query 存入本地交互文件。后续相同 query 搜索会过滤这些资产。这是轻量的负反馈过滤，不会改写 embedding，也不会训练模型。

## 9. 主题回忆检索

除了用户主动搜索，系统还用同一套跨模态向量库生成“光影主题”回忆。入口是：

```swift
SemanticEmbeddingService.thematicSearch(...)
```

当前主题包括“晚霞漫天”“城市夜景”“蓝调时刻”“日出晨光”“黄金时刻”“雨夜霓虹”等，每个主题有一条中英混合 query，例如：

```text
晚霞 日落 sunset colorful sky
```

算法流程：

1. 为每个主题 query 生成文本向量。
2. 对每张照片分别计算与每个主题的点积相似度。
3. 每个主题只维护 `limitPerTheme` 个最高分候选，避免保存全量中间结果。
4. 使用 `max(minimumScore, bestScore - maximumScoreDrop)` 生成主题内阈值。
5. 将满足阈值的资产按时间排序，生成带 `semanticTitle` 的 `PhotoEvent`。

这套机制复用了用户搜索的跨模态能力，但输出不是单张搜索结果，而是主题化照片集合。

## 10. 并发与后台调度

`SemanticEmbeddingService` 是 Swift actor，保证模型、内存索引和数据库写入状态在并发访问下串行一致。

`PhotoLibraryStore` 负责把重任务放到合适时机：

- 首屏启动后先加载照片和 UI，再延迟加载模型和索引。
- 用户正在浏览照片时暂停索引，避免影响交互。
- 应用进入后台时提交 `BGProcessingTaskRequest`。
- 后台任务要求外接电源，最早 15 分钟后执行。
- 精细索引可受 Wi-Fi 策略控制，避免主动下载大量 iCloud 照片。

索引循环刻意使用 batch size 1 和短 sleep。这牺牲了总吞吐量，但降低了 Photos、Vision、Core ML、SQLite 同时工作对前台体验的影响。

## 11. 与回忆聚类的关系

跨模态检索和回忆聚类是相互补充的两套算法：

- 跨模态检索负责“文本描述找照片”和“主题找照片”。
- 回忆聚类负责根据时间、位置和视觉相似性组织事件。

回忆聚类不会直接使用 SigLIP embedding。它主要使用：

- 创建时间间隔。
- 地理距离。
- Vision feature print 距离。
- 文档过滤后的可见照片集合。

因此当前架构中，SigLIP 向量主要服务于语义检索与主题回忆发现，Vision feature print 主要服务于事件边界判断。

## 12. 当前限制与可演进方向

当前实现的主要限制：

- 线性扫描复杂度为 O(N)，照片库极大时搜索耗时会随照片数线性增长。
- SQLite 只负责持久化，不负责向量相似度检索。
- 没有学习式重排；用户“不相关”反馈只做 query 级过滤。
- 没有把时间、地点、收藏、人物等元数据并入语义排序。
- 图片向量只有单一全局 embedding，对小物体、局部文字或复杂场景的召回能力受限。
- 文本 tokenizer 是轻量 Swift 复刻实现，依赖转换脚本导出的 SentencePiece 词表和 score。

未来可以演进的方向：

- 引入端侧 ANN 索引，降低大图库搜索延迟。
- 增加 metadata-aware reranking，把时间、地点、收藏、事件一致性纳入排序。
- 将用户负反馈变成 query expansion 或轻量个性化重排。
- 对长尾查询加入多 query 改写，例如中文 query 自动扩展英文视觉概念。
- 为事件级搜索建立聚合向量，使“某次旅行”“某顿饭”这类结果可以按回忆集合返回。

这些方向目前尚未在代码中实现。
