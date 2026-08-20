#import <Foundation/Foundation.h>
// Syphon 서버 디렉토리 프로토콜: info.v002.Syphon.* 분산 알림
int main(void) {
    @autoreleasepool {
        NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *n in @[@"info.v002.Syphon.ServerAnnounce", @"info.v002.Syphon.ServerUpdate"]) {
            [dnc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
                NSString *name = note.userInfo[@"SyphonServerDescriptionNameKey"];
                NSString *app  = note.userInfo[@"SyphonServerDescriptionAppNameKey"];
                NSString *entry = [NSString stringWithFormat:@"%@ (%@)", name ?: @"(무명)", app ?: @"?"];
                if (![found containsObject:entry]) [found addObject:entry];
            }];
        }
        [dnc postNotificationName:@"info.v002.Syphon.ServerAnnounceRequest"
                           object:nil userInfo:nil deliverImmediately:YES];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
        if (found.count == 0) { printf("등록된 Syphon 서버 없음\n"); return 1; }
        for (NSString *s in found) printf("서버: %s\n", s.UTF8String);
    }
    return 0;
}

/*
 빌드·실행:
   xcrun clang -fobjc-arc -framework Foundation -o /tmp/syphon_probe Tools/syphon_probe.m
   /tmp/syphon_probe

 Delight를 --broadcast 로 띄운 뒤 이걸 돌리면 "서버: Delight (Delight)" 가 나와야 한다.
 OBS를 설치하지 않고도 송출이 살아 있는지 확인할 수 있다.

 주의: 알림 이름은 상수명(SyphonServerAnnounce)이 아니라 실제 문자열
 "info.v002.Syphon.ServerAnnounce" 다. SyphonPrivate.h 의 #define 을 볼 것.
*/
