#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C exceptions into Swift, which cannot catch them natively.
/// CoreBluetooth (e.g. -[CBPeripheral openL2CAPChannel:options:]) raises an
/// NSException via NSAssert when called against a peripheral in a transient bad
/// state; without this shim that becomes an uncatchable abort() / SIGABRT.
@interface HopObjCExceptionCatcher : NSObject
/// Runs `block`. Returns YES on success; on an Objective-C exception, returns NO
/// and populates `error` with the exception name/reason instead of crashing.
+ (BOOL)runBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
