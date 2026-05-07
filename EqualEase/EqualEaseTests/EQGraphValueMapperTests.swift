//
//  EQGraphValueMapperTests.swift
//  EqualEaseTests
//

import CoreGraphics
import XCTest
@testable import EqualEase

final class EQGraphValueMapperTests: XCTestCase {
    private let rect = CGRect(x: 20, y: 10, width: 180, height: 240)

    func testGainMapsToExpectedYCoordinates() {
        let mapper = EQGraphValueMapper(plotRect: rect, bandCount: 10)

        XCTAssertEqual(mapper.y(forGain: 12), rect.minY, accuracy: 0.0001)
        XCTAssertEqual(mapper.y(forGain: 0), rect.midY, accuracy: 0.0001)
        XCTAssertEqual(mapper.y(forGain: -12), rect.maxY, accuracy: 0.0001)
    }

    func testBandIndexMapsAcrossPlotWidth() {
        let mapper = EQGraphValueMapper(plotRect: rect, bandCount: 10)

        XCTAssertEqual(mapper.x(forBand: 0), rect.minX, accuracy: 0.0001)
        XCTAssertEqual(mapper.x(forBand: 9), rect.maxX, accuracy: 0.0001)
        XCTAssertEqual(mapper.x(forBand: 4), rect.minX + rect.width * (4.0 / 9.0), accuracy: 0.0001)
    }

    func testDragYMapsBackToClampedSteppedGain() {
        let mapper = EQGraphValueMapper(plotRect: rect, bandCount: 10)

        XCTAssertEqual(mapper.steppedGain(forY: rect.minY - 100), 12)
        XCTAssertEqual(mapper.steppedGain(forY: rect.maxY + 100), -12)
        XCTAssertEqual(mapper.steppedGain(forY: rect.midY), 0)
    }

    func testDragYUsesHalfDecibelSteps() {
        let mapper = EQGraphValueMapper(plotRect: rect, bandCount: 10)
        let rawGain = 1.26
        let y = mapper.y(forGain: rawGain)

        XCTAssertEqual(mapper.steppedGain(forY: y), 1.5)
        XCTAssertEqual(EQGraphValueMapper.stepped(1.24), 1.0)
        XCTAssertEqual(EQGraphValueMapper.stepped(-1.26), -1.5)
    }
}
