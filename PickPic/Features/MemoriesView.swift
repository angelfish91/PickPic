import SwiftUI

struct MemoriesView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    let onSearch: () -> Void
    @State private var selectedEvent: PhotoEvent?
    @State private var todayIndex = 0
    @State private var recentBatchStart = 0
    @State private var travelBatchStart = 0
    @State private var lightBatchStart = 0
    @State private var capsuleBatchStart = 0
    @State private var exhaustedSections: Set<MemorySection> = []
    @State private var isScrolling = false

    private enum MemorySection: Hashable {
        case today
        case recent
        case travel
        case light
        case capsule
    }

    private var todayEvent: PhotoEvent? {
        let candidates = todayCandidates
        guard !candidates.isEmpty else { return nil }
        return candidates[min(todayIndex, candidates.count - 1)]
    }

    private var todayCandidates: [PhotoEvent] {
        photoLibrary.todayMemoryEvents.isEmpty
            ? Array(photoLibrary.featuredMemoryEvents)
            : photoLibrary.todayMemoryEvents
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 30) {
                header
                AmbientSearchBar(action: onSearch)
                todayMemory
                recentStories
                travelStories
                lightStories
                timeCapsules
                understandingStatus
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 112)
        }
        .onScrollPhaseChange { _, phase in
            let scrolling = switch phase {
            case .tracking, .interacting, .decelerating: true
            case .idle, .animating: false
            @unknown default: false
            }
            guard scrolling != isScrolling else { return }
            isScrolling = scrolling
            if scrolling {
                photoLibrary.beginPhotoBrowsing()
            } else {
                photoLibrary.endPhotoBrowsing()
            }
        }
        .fullScreenCover(item: $selectedEvent) { event in
            EventDetailView(event: event, photoLibrary: photoLibrary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Date.now.formatted(.dateTime.month(.wide).day()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PickPicTheme.secondaryInk)
            Text("回忆")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(PickPicTheme.ink)
        }
    }

    private var todayMemory: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("今日回忆", detail: todayMemoryDetail, section: .today)

            Button {
                selectedEvent = todayEvent
            } label: {
                ZStack(alignment: .bottomLeading) {
                    if let event = todayEvent {
                        PhotoAssetImage(asset: event.coverAsset)
                    } else {
                        LinearGradient(
                            colors: Memory.hero.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.76)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Label(todayMemoryLabel, systemImage: "calendar")
                            .font(.system(size: 11, weight: .bold))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.72))
                        Text(todayEvent?.title ?? "照片正在形成新的回忆")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                        Text(todayEvent?.subtitle ?? "完成照片理解后，这里会出现属于今天的旧时光")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    .padding(22)
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 22, y: 12)
            }
            .buttonStyle(CardPressStyle())
            .disabled(todayEvent == nil)
            exhaustedMessage(for: .today)
        }
    }

    private var recentStories: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("最近值得重温", detail: "从近期照片里发现", section: .recent)

            if photoLibrary.featuredMemoryEvents.isEmpty {
                emptyMemoryCard(
                    icon: "sparkles.rectangle.stack",
                    title: "正在发现近期故事",
                    subtitle: photoLibrary.semanticModelStatus
                )
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(memoryBatch(photoLibrary.featuredMemoryEvents, start: recentBatchStart, count: 4)) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            storyCard(event)
                        }
                        .buttonStyle(CardPressStyle())
                    }
                }
            }
            exhaustedMessage(for: .recent)
        }
    }

    private func storyCard(_ event: PhotoEvent) -> some View {
        HStack(spacing: 15) {
            PhotoAssetImage(asset: event.coverAsset)
                .frame(width: 118, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(event.title)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(PickPicTheme.ink)
                    .lineLimit(2)
                Text(eventDateRange(event))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PickPicTheme.secondaryInk)
                Label("\(event.assets.count) 张照片", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
                Spacer()
                Text(storyReason(event))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PickPicTheme.secondaryInk.opacity(0.78))
            }
            .padding(.vertical, 5)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(PickPicTheme.secondaryInk.opacity(0.45))
        }
        .padding(12)
        .frame(height: 142)
        .background(.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var travelStories: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("旅行轨迹", detail: "排除常驻地点，按连续旅程整理", section: .travel)

            if photoLibrary.travelMemoryEvents.isEmpty {
                emptyMemoryCard(
                    icon: "map.fill",
                    title: "还没有可生成的旅行轨迹",
                    subtitle: "带有位置信息的照片积累后会出现在这里"
                )
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(memoryBatch(photoLibrary.travelMemoryEvents, start: travelBatchStart, count: 3)) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            travelCard(event)
                        }
                        .buttonStyle(CardPressStyle())
                    }
                }
            }
            exhaustedMessage(for: .travel)
        }
    }

    private func travelCard(_ event: PhotoEvent) -> some View {
        ZStack(alignment: .bottomLeading) {
            PhotoAssetImage(asset: event.coverAsset)
            LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Label(photoLibrary.travelLocationNames[event.id] ?? "正在识别地点", systemImage: "location.fill")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(travelDateRange(event))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Text("\(event.assets.count) 张带位置照片")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var lightStories: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("光影时刻", detail: "收藏天空、暮色与城市灯火", section: .light)

            if photoLibrary.lightMemoryEvents.isEmpty {
                emptyMemoryCard(
                    icon: "sun.horizon.fill",
                    title: "正在等待特别的光",
                    subtitle: "晚霞、夜景与晨光积累后会出现在这里"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(memoryBatch(photoLibrary.lightMemoryEvents, start: lightBatchStart, count: 4)) { event in
                            Button {
                                selectedEvent = event
                            } label: {
                                lightCard(event)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                }
                .contentMargins(.horizontal, 0)
            }
            exhaustedMessage(for: .light)
        }
    }

    private func lightCard(_ event: PhotoEvent) -> some View {
        ZStack(alignment: .bottomLeading) {
            PhotoAssetImage(asset: event.coverAsset)
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: lightIcon(for: event.title))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text(event.title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("\(event.assets.count) 张照片")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(width: 178, height: 224)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func lightIcon(for title: String) -> String {
        if title.contains("夜") || title.contains("星") { return "moon.stars.fill" }
        if title.contains("雨") { return "cloud.rain.fill" }
        if title.contains("云") || title.contains("雾") { return "cloud.sun.fill" }
        return "sun.horizon.fill"
    }

    private var timeCapsules: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("时间胶囊", detail: "从往年这个月寄来", section: .capsule)

            if photoLibrary.timeCapsuleEvents.isEmpty {
                emptyMemoryCard(
                    icon: "clock.arrow.circlepath",
                    title: "时间胶囊正在积累",
                    subtitle: "往年这个月的故事会出现在这里"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(memoryBatch(photoLibrary.timeCapsuleEvents, start: capsuleBatchStart, count: 4)) { event in
                            Button {
                                selectedEvent = event
                            } label: {
                                capsuleCard(event)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                }
                .contentMargins(.horizontal, 0)
            }
            exhaustedMessage(for: .capsule)
        }
    }

    private func capsuleCard(_ event: PhotoEvent) -> some View {
        ZStack(alignment: .bottomLeading) {
            PhotoAssetImage(asset: event.coverAsset)
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(yearsAgoText(event.startDate))
                    .font(.system(size: 10.5, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.7))
                Text(event.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                Text("\(event.assets.count) 张照片")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
            .padding(15)
        }
        .frame(width: 178, height: 224)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var understandingStatus: some View {
        HStack(spacing: 14) {
            Image(systemName: photoLibrary.isSemanticIndexing ? "sparkles" : "checkmark.seal.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolEffect(.pulse, isActive: photoLibrary.isSemanticIndexing)
            VStack(alignment: .leading, spacing: 3) {
                Text(photoLibrary.isSemanticIndexing ? "更多回忆正在被发现" : "回忆已准备好")
                    .font(.system(size: 14, weight: .semibold))
                Text(photoLibrary.semanticModelStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
            Spacer()
        }
        .padding(16)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func emptyMemoryCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
            Spacer()
        }
        .padding(18)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func sectionTitle(_ title: String, detail: String, section: MemorySection) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
            Spacer()
            Button(exhaustedSections.contains(section) ? "到底了" : "换一批") {
                replaceBatch(section)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PickPicTheme.secondaryInk)
            .buttonStyle(.plain)
            .disabled(exhaustedSections.contains(section))
        }
    }

    @ViewBuilder
    private func exhaustedMessage(for section: MemorySection) -> some View {
        if exhaustedSections.contains(section) {
            Text("没有更多素材可以生成了，已经到底了")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PickPicTheme.secondaryInk)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
    }

    private func replaceBatch(_ section: MemorySection) {
        switch section {
        case .today:
            if todayIndex + 1 < todayCandidates.count {
                todayIndex += 1
            } else {
                exhaustedSections.insert(.today)
            }
        case .recent:
            recentBatchStart = nextBatchStart(
                current: recentBatchStart,
                total: photoLibrary.featuredMemoryEvents.count,
                step: 4,
                section: section
            )
        case .travel:
            travelBatchStart = nextBatchStart(
                current: travelBatchStart,
                total: photoLibrary.travelMemoryEvents.count,
                step: 3,
                section: section
            )
        case .light:
            lightBatchStart = nextBatchStart(
                current: lightBatchStart,
                total: photoLibrary.lightMemoryEvents.count,
                step: 4,
                section: section
            )
        case .capsule:
            capsuleBatchStart = nextBatchStart(
                current: capsuleBatchStart,
                total: photoLibrary.timeCapsuleEvents.count,
                step: 4,
                section: section
            )
        }
    }

    private func nextBatchStart(
        current: Int,
        total: Int,
        step: Int,
        section: MemorySection
    ) -> Int {
        let next = current + step
        guard next < total else {
            exhaustedSections.insert(section)
            return current
        }
        return next
    }

    private func memoryBatch(_ events: [PhotoEvent], start: Int, count: Int) -> [PhotoEvent] {
        Array(events.dropFirst(start).prefix(count))
    }

    private var todayMemoryDetail: String {
        photoLibrary.todayMemoryEvents.isEmpty ? "从照片故事中精选" : "往年的今天"
    }

    private var todayMemoryLabel: String {
        guard let event = photoLibrary.todayMemoryEvents.first else { return "推荐故事" }
        return yearsAgoText(event.startDate)
    }

    private func yearsAgoText(_ date: Date) -> String {
        let years = max(Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 1, 1)
        return "\(years) 年前"
    }

    private func eventDateRange(_ event: PhotoEvent) -> String {
        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            return event.startDate.formatted(.dateTime.year().month(.wide).day())
        }
        return "\(event.startDate.formatted(.dateTime.year().month().day())) - \(event.endDate.formatted(.dateTime.month().day()))"
    }

    private func travelDateRange(_ event: PhotoEvent) -> String {
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.year, .month, .day], from: event.startDate)
        let endComponents = calendar.dateComponents([.year, .month, .day], from: event.endDate)
        let start = "\(startComponents.year ?? 0) 年 \(startComponents.month ?? 0) 月 \(startComponents.day ?? 0) 日"
        guard !calendar.isDate(event.startDate, inSameDayAs: event.endDate) else {
            return start
        }
        if startComponents.year == endComponents.year {
            return "\(start)～\(endComponents.month ?? 0) 月 \(endComponents.day ?? 0) 日"
        }
        return "\(start)～\(endComponents.year ?? 0) 年 \(endComponents.month ?? 0) 月 \(endComponents.day ?? 0) 日"
    }

    private func storyReason(_ event: PhotoEvent) -> String {
        if event.semanticTitle != nil { return "内容鲜明，值得重温" }
        if event.assets.contains(where: { $0.location != nil }) { return "记录了一段地点与时光" }
        if event.assets.count >= 12 { return "一组完整的照片故事" }
        return "最近发生的照片故事"
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
