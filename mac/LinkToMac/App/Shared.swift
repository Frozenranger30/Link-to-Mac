import AppKit
import SwiftUI

extension Date {
    init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// "14:32" for today, "Gestern", weekday within a week, otherwise a short date.
    var shortRelative: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return String(localized: "Gestern") }
        if let days = cal.dateComponents([.day], from: self, to: Date()).day, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}

struct EmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 32

    private var initials: String {
        let letters = name.split(separator: " ").compactMap { $0.first }.filter { $0.isLetter }
        if letters.isEmpty { return "#" }
        return String(letters.prefix(2)).uppercased()
    }

    private var color: Color {
        let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .mint]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if initials == "#" {
                Image(systemName: "person.fill").foregroundStyle(.white).font(.system(size: size * 0.45))
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension NSImage {
    convenience init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }
}
