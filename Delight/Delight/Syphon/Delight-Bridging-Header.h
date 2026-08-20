//
//  Delight-Bridging-Header.h
//  Objective-C 소스를 Swift에서 쓰기 위한 브리징 헤더.
//
//  Syphon은 프레임워크로 임베드하지 않고 **소스를 앱 타깃에 직접 넣었다**.
//  이유: 프레임워크 임베드는 pbxproj에 링크·임베드·서명 단계를 추가해야 하는데,
//  동기화 폴더를 쓰는 이 프로젝트에서는 소스를 넣는 쪽이 빌드 설정을 덜 건드린다.
//  (Syphon은 Simplified BSD — Syphon/License.txt 참조)
//

#import "SyphonMetalServer.h"
#import "SyphonServerDirectory.h"
