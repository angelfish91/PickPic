import SwiftUI

struct Memory: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]
}

extension Memory {
    static let hero = Memory(
        title: "海风经过的下午",
        subtitle: "去年六月 · 青岛 · 47 张照片",
        icon: "water.waves",
        colors: [
            Color(red: 0.16, green: 0.31, blue: 0.40),
            Color(red: 0.58, green: 0.69, blue: 0.70),
            Color(red: 0.91, green: 0.66, blue: 0.46)
        ]
    )

    static let samples = [
        Memory(
            title: "山里的周末",
            subtitle: "32 张照片",
            icon: "mountain.2.fill",
            colors: [.init(red: 0.18, green: 0.25, blue: 0.19), .init(red: 0.62, green: 0.60, blue: 0.42)]
        ),
        Memory(
            title: "晚餐之后",
            subtitle: "18 张照片",
            icon: "wineglass.fill",
            colors: [.init(red: 0.27, green: 0.12, blue: 0.12), .init(red: 0.82, green: 0.48, blue: 0.31)]
        ),
        Memory(
            title: "城市漫游",
            subtitle: "65 张照片",
            icon: "building.2.fill",
            colors: [.init(red: 0.16, green: 0.18, blue: 0.22), .init(red: 0.58, green: 0.61, blue: 0.64)]
        )
    ]
}
