import Foundation

struct LayoutItem {
    let id: String
    let start: Date
    let end: Date
}

struct PositionedItem: Equatable {
    let id: String
    let column: Int
    let columnCount: Int
}

/// Algoritmo clasico de calendario: eventos que se solapan transitivamente
/// forman un cluster; dentro del cluster cada evento toma la primera columna
/// libre y todos dividen el ancho entre el total de columnas del cluster.
enum OverlapLayout {
    static func layout(_ items: [LayoutItem]) -> [String: PositionedItem] {
        let sorted = items.sorted { a, b in
            a.start != b.start ? a.start < b.start : a.end > b.end
        }
        var result: [String: PositionedItem] = [:]
        var cluster: [(item: LayoutItem, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            guard !cluster.isEmpty else { return }
            let count = columnEnds.count
            for (item, col) in cluster {
                result[item.id] = PositionedItem(id: item.id, column: col, columnCount: count)
            }
            cluster.removeAll()
            columnEnds.removeAll()
        }

        for item in sorted {
            if item.start >= clusterEnd {
                closeCluster()
                clusterEnd = item.end
            } else {
                clusterEnd = max(clusterEnd, item.end)
            }
            var placed = false
            for (i, end) in columnEnds.enumerated() where item.start >= end {
                columnEnds[i] = item.end
                cluster.append((item, i))
                placed = true
                break
            }
            if !placed {
                columnEnds.append(item.end)
                cluster.append((item, columnEnds.count - 1))
            }
        }
        closeCluster()
        return result
    }
}
