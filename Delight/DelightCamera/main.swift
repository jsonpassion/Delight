//
//  main.swift
//  DelightCamera — CMIO 카메라 확장 진입점.
//
//  ⚠️ top-level 코드다. 앱 타깃(Delight/Delight/)에 두면 빌드가 깨진다.
//  이 폴더는 별도 타깃이므로 괜찮다.
//
//  확장은 앱과 **다른 프로세스**로, 다른 사용자 계정에서 돌아간다.
//  Xcode 콘솔에 로그가 안 나오므로 Console.app에서 프로세스 이름으로 본다.
//

import Foundation
import CoreMediaIO

let providerSource = DelightProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
