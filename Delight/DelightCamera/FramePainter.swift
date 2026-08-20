//
//  FramePainter.swift
//  앱이 연결되기 전에 내보낼 안내 화면.
//
//  검은 화면을 내보내면 사용자는 "고장났다"고 판단한다.
//  무엇을 해야 하는지 보이는 편이 낫다.
//

import Foundation
import CoreVideo
import CoreGraphics
import CoreText

enum FramePainter {

    static func drawPlaceholder(into pixelBuffer: CVPixelBuffer, frameIndex: UInt64) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        context.setFillColor(red: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 텅스텐 색 맥동 — 프레임이 실제로 갱신되고 있음을 보여준다.
        let pulse = 0.5 + 0.5 * sin(Double(frameIndex) * 0.05)
        context.setFillColor(red: 0.62 * pulse + 0.1, green: 0.34 * pulse + 0.06,
                             blue: 0.06 * pulse + 0.02, alpha: 1)
        let radius = Double(min(width, height)) * 0.06
        context.fillEllipse(in: CGRect(x: Double(width) / 2 - radius,
                                       y: Double(height) * 0.62 - radius,
                                       width: radius * 2, height: radius * 2))

        draw(text: "Delight", in: context, size: Double(height) * 0.075,
             y: Double(height) * 0.40, width: width, alpha: 0.92)
        draw(text: "앱을 실행하고 송출을 켜세요", in: context, size: Double(height) * 0.038,
             y: Double(height) * 0.30, width: width, alpha: 0.55)
    }

    private static func draw(text: String, in context: CGContext,
                             size: Double, y: Double, width: Int, alpha: Double) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        // 확장은 AppKit을 링크하지 않는다. NSAttributedString.Key의 .font/.foregroundColor는
        // AppKit/UIKit이 제공하는 확장이므로 CoreText 상수를 직접 쓴다.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: alpha),
        ]
        let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString,
                                                  attributes as CFDictionary)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (Double(width) - Double(bounds.width)) / 2.0, y: y)
        CTLineDraw(line, context)
    }
}
