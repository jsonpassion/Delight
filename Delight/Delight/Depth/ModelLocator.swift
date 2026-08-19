//
//  ModelLocator.swift
//  모델 패키지 위치를 찾는다.
//
//  개발 중에는 리포의 Models/ 를 쓰고(gitignore, 142MB), 배포 시에는 번들에 넣는다.
//  Tools/fetch_models.sh 가 Models/ 를 만든다.
//

import Foundation

enum ModelLocator {

    static let packageName = "DepthAnythingV2Small"

    /// 번들 → 리포의 Models/ 순으로 찾는다.
    static func mtlpackageURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: packageName, withExtension: "mtlpackage") {
            return bundled
        }
        // TODO(배포): 번들에 복사하는 빌드 페이즈를 넣고 이 폴백을 제거한다.
        // 개발 편의를 위해 소스 파일 위치에서 리포 루트를 거슬러 올라간다.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("Models")
                .appendingPathComponent("\(packageName).mtlpackage")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
