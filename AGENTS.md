# AGENTS.md

## Project Overview
PickPic is a native SwiftUI iOS photo app. It reads the user's photo library, groups photos into memories/events, filters non-photo content such as documents and QR codes, supports semantic photo search, and can generate memory videos with simple synthesized music.

The app target is `PickPic` in `PickPic.xcodeproj`. The project uses Swift 5, SwiftUI, Photos, Vision, Core ML, AVFoundation, BackgroundTasks, SQLite3, and CoreImage. Deployment target is iOS 18.0, with iPhone/iPad support and Mac Catalyst enabled.

## Repository Layout
- `PickPic/App/`: app entry point. `PickPicApp.swift` owns the shared `PhotoLibraryStore` and scene phase handling.
- `PickPic/Features/`: SwiftUI screens and feature views.
  - `RootView.swift`: tab shell, launch preparation overlay, search sheet.
  - `MemoriesView.swift`: memory/event browsing and video generation flows.
  - `LibraryView.swift`: photo grid, visual/semantic scan status, thumbnail preheating.
  - `SearchBar.swift`: search UI and semantic search results.
  - `PhotoDetailView.swift`, `EventDetailView.swift`, `LivePhotoViews.swift`, `ProfileView.swift`, `AdaptiveDock.swift`: detail views and shared UI surfaces.
- `PickPic/Models/`: app state, Photos/Vision/Core ML services, caches, video generation, and thumbnail pipeline.
  - `PhotoLibraryStore.swift`: central observable store, photo permission/loading, event cache, visual analysis cache, semantic indexing orchestration, background task registration, and user feedback state.
  - `SemanticEmbeddingService.swift`: SigLIP Core ML model loading, tokenizer use, SQLite semantic index, text/image embedding search.
  - `VisualAnalysisService.swift`: Vision OCR/barcode/classification/feature-print analysis and document filtering.
  - `MemoryVideoGenerator.swift`: vertical MP4 generation, transitions, Live Photo frame extraction, synthesized music, save-to-library.
  - `SigLIPTokenizer.swift`: local tokenizer used by the text encoder.
- `PickPic/Design/`: theme colors, material surface modifier, and brand mark.
- `PickPic/Assets.xcassets/`: app icon, accent color, brand icon.
- `PickPic/Models/SigLIPResources/`: bundled SigLIP tokenizer resources and expected location for compiled model resources.
- `Tools/convert_siglip.py`: converts `google/siglip-base-patch16-256-multilingual` into Core ML image/text encoders and tokenizer assets.
- `LocalModels/`: ignored local model output from conversion. Do not assume it is present in a fresh clone.

## Build And Run
- Open in Xcode: `open PickPic.xcodeproj`
- List project metadata: `xcodebuild -list -project PickPic.xcodeproj`
- Build from CLI:
  ```sh
  xcodebuild -project PickPic.xcodeproj -scheme PickPic -configuration Debug -destination 'generic/platform=iOS Simulator' build
  ```

There is currently no separate test target in the project. For changes with behavioral risk, at minimum run an Xcode build. If touching photo library flows, semantic indexing, video generation, or background processing, also run manually on a simulator/device that can exercise Photos permissions.

## Model Resources
Semantic search expects these resources in the app bundle:
- `SigLIPImageEncoder.mlmodelc`
- `SigLIPTextEncoder.mlmodelc`
- `SigLIPTokenizer.bundle/tokenizer.json`

`SemanticEmbeddingService.prepare()` looks for the compiled Core ML resources by exact name and the tokenizer JSON under `SigLIPTokenizer.bundle`. The tokenizer bundle is tracked under `PickPic/Models/SigLIPResources/`; `.mlpackage` model packages under this directory and all of `LocalModels/` are gitignored.

Use `Tools/convert_siglip.py` only when regenerating model assets. It depends on Python packages such as `coremltools`, `torch`, and `transformers`, downloads `google/siglip-base-patch16-256-multilingual`, and writes output under `LocalModels/SigLIPMultilingual`. Review model size and distribution before moving generated artifacts into the app bundle.

## App State And Persistence
- `PhotoLibraryStore` is the main state owner. Keep Photos access, cache reconciliation, visual scanning, semantic indexing, and background task coordination there unless there is a strong reason to split behavior.
- Event grouping is cached with SQLite through `PhotoEventCache`.
- Semantic embeddings are stored in an application support SQLite database named `siglip-multilingual-index-v2.sqlite`.
- Older semantic JSON indexes may be migrated from `siglip-multilingual-index-v1.json`.
- Visual analysis cache is persisted separately by `PhotoLibraryStore`.
- Background processing uses `com.sparrowsong.PickPic.background-index`; keep this identifier aligned between `PhotoLibraryStore`, `PickPic-Info.plist`, and build settings.

## Coding Conventions
- Follow the existing SwiftUI style: small feature views in `PickPic/Features`, shared model/service code in `PickPic/Models`, shared visual constants in `PickPic/Design`.
- Prefer Swift concurrency (`async`/`await`, actors, `Task`) for asynchronous Photos, Vision, Core ML, and video work.
- Keep UI updates on the main actor. `PhotoLibraryStore` is observable app state and many of its methods intentionally coordinate async work back to UI-facing properties.
- Avoid blocking the main thread with Photos image requests, Vision analysis, Core ML inference, SQLite work, or AVFoundation rendering.
- Preserve the app's Chinese user-facing copy unless intentionally changing UX language.
- Use `PickPicTheme` and existing material/surface patterns for visual consistency.
- Be careful with files under `PickPic.xcodeproj`; the project uses a file-system-synchronized root group, so new files under `PickPic/` usually do not require manual project file edits.

## Important Pitfalls
- Do not delete or rewrite ignored local model outputs in `LocalModels/` unless the task is specifically about model conversion.
- Do not assume semantic search is available if the compiled `.mlmodelc` resources are missing; the app reports model-loading status through `semanticModelStatus`.
- Photos library and iCloud-backed assets may be unavailable or slow. Existing code distinguishes quick thumbnail indexing from refined indexing and retries failures.
- Visual analysis intentionally runs gently in the background to preserve navigation responsiveness.
- Avoid broad `rg` searches over tokenizer JSON files; they are huge and can flood output. Prefer globs such as `rg PATTERN PickPic --glob '!PickPic/Models/SigLIPResources/**'` when searching source code.
- The worktree may contain user changes. Inspect `git status --short` before editing and never revert unrelated changes.
