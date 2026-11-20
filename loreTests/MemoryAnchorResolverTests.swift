import Testing
@testable import lore

struct MemoryAnchorResolverTests {
    @Test func resolvesYearsAndRelativeYears() {
        #expect(resolve(.none) == nil)
        #expect(resolve(.year(start: 2004, end: 2004)) == .init(
            time: .init(precision: .year, startDate: "2004-01-01", endDate: "2004-12-31"),
            isPrivate: false
        ))
        #expect(resolve(.year(start: 2003, end: 2005)) == .init(
            time: .init(precision: .period, startDate: "2003-01-01", endDate: "2005-12-31"),
            isPrivate: false
        ))
        #expect(resolve(.yearsAgo(min: 3, max: 5)) == .init(
            time: .init(precision: .period, startDate: "2021-01-01", endDate: "2023-12-31"),
            isPrivate: false
        ))
        #expect(resolve(.yearsAgo(min: 1, max: 1), birthYear: 0)?.time.precision == .year)
    }

    @Test func ageWindowsAllowForUnknownBirthdayAndStayOnDevice() {
        #expect(resolve(.age(start: 7, end: 7)) == .init(
            time: .init(precision: .period, startDate: "1997-01-01", endDate: "1998-12-31"),
            isPrivate: true
        ))
        #expect(resolve(.age(start: 7, end: 10)) == .init(
            time: .init(precision: .period, startDate: "1997-01-01", endDate: "2001-12-31"),
            isPrivate: true
        ))
    }

    @Test(arguments: zip(
        MemoryAnchor.LifeStage.allCases,
        ["1990", "1996", "2002", "2008", "2012"]
    ))
    func lifeStagesMatchTheDial(stage: MemoryAnchor.LifeStage, startYear: String) throws {
        let period = try #require(LifeDial.draftPeriods(birthYear: 1990, through: 2026)
            .first { String($0.startYear) == startYear })
        #expect(resolve(.lifeStage(stage)) == .init(
            time: .init(precision: .period, startDate: "\(period.startYear)-01-01", endDate: "\(period.endYear)-12-31"),
            isPrivate: true
        ))
    }

    @Test(arguments: [
        .year(start: 1989, end: 1991), .year(start: 2000, end: 1999),
        .year(start: 2025, end: 2026), .year(start: 2027, end: 2027),
        .yearsAgo(min: 0, max: 0), .yearsAgo(min: 5, max: 4), .yearsAgo(min: -1, max: 4),
        .yearsAgo(min: 30, max: Int.max), .age(start: -1, end: 3),
        .age(start: 5, end: 4), .age(start: 35, end: 35),
        .age(start: 0, end: Int.max)
    ] as [MemoryAnchor])
    func rejectsOutOfRangeOrReversedAnchors(anchor: MemoryAnchor) {
        #expect(resolve(anchor) == nil)
    }

    @Test func missingBirthYearLeavesAgeAndLifeStageUnresolved() {
        #expect(resolve(.age(start: 7, end: 7), birthYear: 0) == nil)
        #expect(resolve(.lifeStage(.teenageYears), birthYear: 0) == nil)
        #expect(resolve(.lifeStage(.collegeYears), birthYear: 2012) == nil)
        #expect(resolve(.lifeStage(.teenageYears), birthYear: 2012) == nil)
        #expect(resolve(.year(start: 2004, end: 2004), birthYear: 0) != nil)
    }

    private func resolve(_ anchor: MemoryAnchor, birthYear: Int = 1990) -> MemoryAnchorResolver.Resolution? {
        MemoryAnchorResolver.resolve(anchor, recordedDay: "2026-11-19", birthYear: birthYear)
    }
}
