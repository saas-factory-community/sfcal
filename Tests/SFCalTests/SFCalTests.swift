import XCTest
@testable import SFCal

final class OverlapLayoutTests: XCTestCase {
    private func date(_ h: Int, _ m: Int = 0) -> Date {
        DateKit.cal.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: h, minute: m))!
    }

    func testNoOverlapSingleColumn() {
        let items = [
            LayoutItem(id: "a", start: date(9), end: date(10)),
            LayoutItem(id: "b", start: date(10), end: date(11)),
            LayoutItem(id: "c", start: date(14), end: date(15)),
        ]
        let pos = OverlapLayout.layout(items)
        XCTAssertEqual(pos["a"], PositionedItem(id: "a", column: 0, columnCount: 1))
        XCTAssertEqual(pos["b"], PositionedItem(id: "b", column: 0, columnCount: 1))
        XCTAssertEqual(pos["c"], PositionedItem(id: "c", column: 0, columnCount: 1))
    }

    func testTwoOverlappingSplitInTwoColumns() {
        let items = [
            LayoutItem(id: "a", start: date(9), end: date(11)),
            LayoutItem(id: "b", start: date(10), end: date(12)),
        ]
        let pos = OverlapLayout.layout(items)
        XCTAssertEqual(pos["a"]?.column, 0)
        XCTAssertEqual(pos["b"]?.column, 1)
        XCTAssertEqual(pos["a"]?.columnCount, 2)
        XCTAssertEqual(pos["b"]?.columnCount, 2)
    }

    func testChainReusesFreedColumn() {
        // a 9-11, b 9-10, c 10-11 → c reusa la columna de b; cluster de 2 columnas
        let items = [
            LayoutItem(id: "a", start: date(9), end: date(11)),
            LayoutItem(id: "b", start: date(9), end: date(10)),
            LayoutItem(id: "c", start: date(10), end: date(11)),
        ]
        let pos = OverlapLayout.layout(items)
        XCTAssertEqual(pos["a"]?.column, 0)
        XCTAssertEqual(pos["b"]?.column, 1)
        XCTAssertEqual(pos["c"]?.column, 1)
        XCTAssertEqual(pos.values.map(\.columnCount), [2, 2, 2])
    }

    func testSeparateClustersDontShareWidth() {
        let items = [
            LayoutItem(id: "a", start: date(9), end: date(10, 30)),
            LayoutItem(id: "b", start: date(9, 30), end: date(10)),
            LayoutItem(id: "c", start: date(15), end: date(16)),
        ]
        let pos = OverlapLayout.layout(items)
        XCTAssertEqual(pos["a"]?.columnCount, 2)
        XCTAssertEqual(pos["c"]?.columnCount, 1)
    }

    func testTripleOverlap() {
        let items = [
            LayoutItem(id: "a", start: date(9), end: date(12)),
            LayoutItem(id: "b", start: date(9, 30), end: date(11)),
            LayoutItem(id: "c", start: date(10), end: date(11, 30)),
        ]
        let pos = OverlapLayout.layout(items)
        XCTAssertEqual(Set(pos.values.map(\.column)), [0, 1, 2])
        XCTAssertEqual(pos.values.map(\.columnCount), [3, 3, 3])
    }
}

final class SyncMergeTests: XCTestCase {
    private func gevent(_ id: String, summary: String? = nil, cancelled: Bool = false,
                        startISO: String = "2026-08-15T09:00:00Z") -> GEvent {
        GEvent(id: id, etag: nil, status: cancelled ? "cancelled" : "confirmed",
               summary: summary ?? id, description: nil, location: nil,
               start: GEventTime(date: nil, dateTime: startISO, timeZone: nil),
               end: GEventTime(date: nil, dateTime: "2026-08-15T10:00:00Z", timeZone: nil),
               recurringEventId: nil, updated: nil, extendedProperties: nil)
    }

    private func calEvent(_ id: String, summary: String = "x") -> CalEvent {
        CalEvent(id: id, calendarId: "cal1", accountId: "personal", summary: summary,
                 start: Date(), end: Date().addingTimeInterval(3600),
                 isAllDay: false, status: "confirmed")
    }

    func testUpsertNewAndExisting() {
        let current = [calEvent("a", summary: "viejo")]
        let out = SyncMerge.apply(current: current,
                                  delta: [gevent("a", summary: "nuevo"), gevent("b")],
                                  calendarId: "cal1", accountId: "personal")
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first { $0.id == "a" }?.summary, "nuevo")
        XCTAssertNotNil(out.first { $0.id == "b" })
    }

    func testCancelledRemoves() {
        let current = [calEvent("a"), calEvent("b")]
        let out = SyncMerge.apply(current: current,
                                  delta: [gevent("a", cancelled: true)],
                                  calendarId: "cal1", accountId: "personal")
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    func testCancelledUnknownIdIsNoop() {
        let current = [calEvent("a")]
        let out = SyncMerge.apply(current: current,
                                  delta: [gevent("zz", cancelled: true)],
                                  calendarId: "cal1", accountId: "personal")
        XCTAssertEqual(out.map(\.id), ["a"])
    }
}

final class GDateTests: XCTestCase {
    func testParseRFC3339WithOffset() {
        let d = GDate.parse("2026-08-15T09:30:00-06:00")
        XCTAssertNotNil(d)
        let utc = GDate.parse("2026-08-15T15:30:00Z")
        XCTAssertEqual(d, utc)
    }

    func testParseAllDay() {
        let d = GDate.parse("2026-08-15")
        XCTAssertNotNil(d)
        XCTAssertEqual(DateKit.cal.component(.hour, from: d!), 0)
    }

    func testAllDayEventMapsToAllDay() {
        let g = GEvent(id: "x", etag: nil, status: "confirmed", summary: "Objetivo",
                       description: nil, location: nil,
                       start: GEventTime(date: "2026-08-15", dateTime: nil, timeZone: nil),
                       end: GEventTime(date: "2026-08-16", dateTime: nil, timeZone: nil),
                       recurringEventId: nil, updated: nil, extendedProperties: nil)
        let e = g.toCalEvent(calendarId: "c", accountId: "a")
        XCTAssertEqual(e?.isAllDay, true)
    }

    func testCancelledMapsToNil() {
        let g = GEvent(id: "x", etag: nil, status: "cancelled", summary: nil,
                       description: nil, location: nil, start: nil, end: nil,
                       recurringEventId: nil, updated: nil, extendedProperties: nil)
        XCTAssertNil(g.toCalEvent(calendarId: "c", accountId: "a"))
    }

    func testWeekStartsMonday() {
        // 15 ago 2026 = sábado; la semana debe empezar lunes 10
        let sat = DateKit.cal.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let week = DateKit.weekDays(sat)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(DateKit.cal.component(.weekday, from: week[0]), 2)  // lunes
        XCTAssertEqual(DateKit.cal.component(.day, from: week[0]), 10)
    }

    func testSnap15() {
        XCTAssertEqual(snap15(0), 0)
        XCTAssertEqual(snap15(7), 0)
        XCTAssertEqual(snap15(8), 15)
        XCTAssertEqual(snap15(52), 45)
        XCTAssertEqual(snap15(53), 60)
    }
}

final class TodoistDueTests: XCTestCase {
    func testDateOnly() {
        let r = TodoistDue.parse("2026-08-15")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.1, false)
        XCTAssertEqual(DateKit.cal.component(.day, from: r!.0), 15)
    }

    func testNaiveLocalDatetime() {
        let r = TodoistDue.parse("2026-08-15T14:00:00")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.1, true)
        XCTAssertEqual(DateKit.cal.component(.hour, from: r!.0), 14)
    }

    func testRFC3339WithOffset() {
        let r = TodoistDue.parse("2026-08-15T20:00:00Z")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.1, true)
    }

    func testGarbageIsNil() {
        XCTAssertNil(TodoistDue.parse("mañana"))
    }
}
