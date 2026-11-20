import Foundation

public struct TreemapRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
    public static let zero = TreemapRect(x: 0, y: 0, width: 0, height: 0)
}

/// Squarified treemap layout (Bruls, Huizing and van Wijk, 2000).
public enum Treemap {
    /// One rectangle per value, in the same order as `values`. Areas are proportional to
    /// the values; zero or negative values get zero-size rectangles.
    public static func squarify(_ values: [Double], in rect: TreemapRect) -> [TreemapRect] {
        var result = Array(repeating: TreemapRect.zero, count: values.count)
        let positive = values.enumerated().filter { $0.element > 0 && $0.element.isFinite }
        let total = positive.reduce(0) { $0 + $1.element }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        // Largest first, scaled to the rectangle's area.
        let scale = rect.area / total
        let items = positive.sorted { $0.element > $1.element }.map { (index: $0.offset, area: $0.element * scale) }

        var remaining = rect
        var start = 0
        while start < items.count {
            let side = min(remaining.width, remaining.height)
            var end = start + 1
            var rowArea = items[start].area
            var best = worst(items[start..<end].map(\.area), side: side, sum: rowArea)
            while end < items.count {
                let candidateSum = rowArea + items[end].area
                let candidate = worst(items[start...end].map(\.area), side: side, sum: candidateSum)
                if candidate > best { break }
                best = candidate
                rowArea = candidateSum
                end += 1
            }

            // Lay the row along the shorter side.
            let row = items[start..<end]
            let isLastRow = end == items.count
            if remaining.width >= remaining.height {
                let thickness = isLastRow ? remaining.width : rowArea / remaining.height
                var y = remaining.y
                for (offset, item) in row.enumerated() {
                    let isLast = offset == row.count - 1
                    let height = isLast ? remaining.y + remaining.height - y : item.area / thickness
                    result[item.index] = TreemapRect(x: remaining.x, y: y, width: thickness, height: height)
                    y += height
                }
                remaining = TreemapRect(x: remaining.x + thickness, y: remaining.y, width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                let thickness = isLastRow ? remaining.height : rowArea / remaining.width
                var x = remaining.x
                for (offset, item) in row.enumerated() {
                    let isLast = offset == row.count - 1
                    let width = isLast ? remaining.x + remaining.width - x : item.area / thickness
                    result[item.index] = TreemapRect(x: x, y: remaining.y, width: width, height: thickness)
                    x += width
                }
                remaining = TreemapRect(x: remaining.x, y: remaining.y + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
            }
            start = end
        }
        return result
    }

    /// The worst aspect ratio in a row laid along `side`.
    private static func worst(_ areas: [Double], side: Double, sum: Double) -> Double {
        guard let largest = areas.max(), let smallest = areas.min(), sum > 0, side > 0, smallest > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}
