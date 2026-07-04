#import "HopObjCExceptionCatcher.h"

@implementation HopObjCExceptionCatcher

+ (BOOL)runBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *ex) {
        if (error) {
            NSDictionary *info = @{
                NSLocalizedDescriptionKey: ex.reason ?: ex.name ?: @"ObjC exception",
                @"ExceptionName": ex.name ?: @"",
            };
            *error = [NSError errorWithDomain:@"HopObjCException" code:1 userInfo:info];
        }
        return NO;
    }
}

@end
