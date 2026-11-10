import CoreGraphics
import Foundation

/// 面積が値に比例する長方形に分割する（Squarified treemap, Bruls et al.）。仕様 12.4。
public enum TreemapLayout {
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        // 値を面積に換算し、大きい順に並べて配置してから元の順序に戻す。
        let scale = Double(rect.width * rect.height) / total
        let order = values.indices.sorted { values[$0] > values[$1] }
        let areas = order.map { max(values[$0], 0) * scale }

        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var row: [Int] = []
        var index = 0

        while index < areas.count {
            let candidate = row + [index]
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(candidate.map { areas[$0] }, side: side) <= worst(row.map { areas[$0] }, side: side) {
                row = candidate
                index += 1
            } else {
                remaining = place(row, areas: areas, order: order, in: remaining, into: &result)
                row = []
            }
        }
        if !row.isEmpty {
            _ = place(row, areas: areas, order: order, in: remaining, into: &result)
        }
        return result
    }

    /// 行内で最も細長い長方形の縦横比。
    static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let maxArea = row.max(), let minArea = row.min(), minArea > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * maxArea / sumSquared, sumSquared / (sideSquared * minArea))
    }

    /// 短い辺に沿って1行を配置し、残りの領域を返す。
    static func place(_ row: [Int], areas: [Double], order: [Int], in rect: CGRect, into result: inout [CGRect]) -> CGRect {
        let sum = row.map { areas[$0] }.reduce(0, +)
        if rect.width >= rect.height {
            let width = CGFloat(sum) / rect.height
            var y = rect.minY
            for index in row {
                let height = CGFloat(areas[index]) / width
                result[order[index]] = CGRect(x: rect.minX, y: y, width: width, height: height)
                y += height
            }
            return CGRect(x: rect.minX + width, y: rect.minY, width: max(rect.width - width, 0), height: rect.height)
        } else {
            let height = CGFloat(sum) / rect.width
            var x = rect.minX
            for index in row {
                let width = CGFloat(areas[index]) / height
                result[order[index]] = CGRect(x: x, y: rect.minY, width: width, height: height)
                x += width
            }
            return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(rect.height - height, 0))
        }
    }
}
