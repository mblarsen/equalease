//
//  LocalNetworkRemoteHTMLTests.swift
//  EqualEaseTests
//

import AppKit
import XCTest
@testable import EqualEase

final class LocalNetworkRemoteHTMLTests: XCTestCase {
    func testRemoteHTMLPublishesFaviconAndAppleTouchIcon() {
        let html = LocalNetworkControlServer.remoteHTML(webSocketPath: "/ws")

        XCTAssertTrue(html.contains(#"<link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">"#))
        XCTAssertTrue(html.contains(#"<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">"#))
        XCTAssertTrue(html.contains(#"<meta name="apple-mobile-web-app-title" content="EqualEase Remote">"#))
        XCTAssertTrue(html.contains(##"<meta name="theme-color" content="#f97316">"##))
    }

    func testRemoteIconPNGUsesRequestedPixelSize() throws {
        let source = solidSourceIcon()

        let data = try XCTUnwrap(LocalNetworkControlServer.remoteIconPNG(size: 180, source: source))
        let pngSignature = [UInt8](data.prefix(8))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))

        XCTAssertEqual(pngSignature, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        XCTAssertEqual(bitmap.pixelsWide, 180)
        XCTAssertEqual(bitmap.pixelsHigh, 180)
    }

    func testRemoteAppleTouchIconCompositesTransparentAppIconOntoOpaqueOrangeBackground() throws {
        let source = transparentPaddedSourceIcon()

        let data = try XCTUnwrap(LocalNetworkControlServer.remoteAppleTouchIconPNG(size: 180, source: source))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(NSColorSpace.deviceRGB) ?? bitmap.colorAt(x: 0, y: 0))

        XCTAssertEqual(corner.alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(corner.redComponent, 0.7)
        XCTAssertGreaterThan(corner.greenComponent, 0.25)
        XCTAssertLessThan(corner.blueComponent, 0.3)
    }

    func testRemoteHTMLIncludesPairingAndTokenReconnectFlow() {
        let html = LocalNetworkControlServer.remoteHTML(webSocketPath: "/ws")

        XCTAssertTrue(html.contains("EqualEase Settings &gt; General &gt; Local Network Remote"))
        XCTAssertTrue(html.contains("equalEaseRemoteCredentialV1"))
        XCTAssertTrue(html.contains("send('auth', { clientID: credential.clientID, token: credential.token }, 'auth')"))
        XCTAssertTrue(html.contains("send('pair', { code, clientName: clientName.value || 'Phone Remote' }, 'pair')"))
        XCTAssertTrue(html.contains("Paired access protects remote control on your trusted local network."))
        XCTAssertFalse(html.contains("No authentication"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("development remote"))
    }

    func testRemoteHTMLDoesNotRequireSecureContextRandomUUIDForCommands() {
        let html = LocalNetworkControlServer.remoteHTML(webSocketPath: "/ws")

        XCTAssertTrue(html.contains("function requestId()"))
        XCTAssertTrue(html.contains("typeof globalThis.crypto.randomUUID === 'function'"))
        XCTAssertTrue(html.contains("req-${Date.now()}-${Math.random().toString(16).slice(2)}"))
        XCTAssertFalse(html.contains("id = crypto.randomUUID()"))
    }

    func testRemoteHTMLUsesPointerAndTouchEventsForPresetButtons() {
        let html = LocalNetworkControlServer.remoteHTML(webSocketPath: "/ws")

        XCTAssertTrue(html.contains("function pressPreset"))
        XCTAssertTrue(html.contains("button.type = 'button'"))
        XCTAssertTrue(html.contains("button.addEventListener('pointerup', event => pressPreset(event, preset))"))
        XCTAssertTrue(html.contains("button.addEventListener('touchend', event => pressPreset(event, preset), { passive: false })"))
        XCTAssertTrue(html.contains("button.addEventListener('click', event => pressPreset(event, preset))"))
    }

    func testRemoteHTMLLetsWholeVolumeAndPreampCardsActAsSliders() {
        let html = LocalNetworkControlServer.remoteHTML(webSocketPath: "/ws")

        XCTAssertTrue(html.contains("id=\"volumeCard\""))
        XCTAssertTrue(html.contains("id=\"preampCard\""))
        XCTAssertTrue(html.contains("function bindCardSlider"))
        XCTAssertTrue(html.contains("setControlFromCardPointer"))
        XCTAssertTrue(html.contains("bindCardSlider('volumeCard', volume, volumeValue, 'set_volume', 100)"))
        XCTAssertTrue(html.contains("bindCardSlider('preampCard', preamp, preampValue, 'set_preamp', 100)"))
    }

    private func solidSourceIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        image.unlockFocus()
        return image
    }

    private func transparentPaddedSourceIcon() -> NSImage {
        let size = 1024
        let imageSize = NSSize(width: size, height: size)
        let imageRect = NSRect(origin: .zero, size: imageSize)
        let contentRect = NSRect(x: 256, y: 256, width: 512, height: 512)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = imageSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        imageRect.fill()
        NSColor.white.setFill()
        contentRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: imageSize)
        image.addRepresentation(bitmap)
        return image
    }
}
