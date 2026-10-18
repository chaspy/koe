#import "KoeObjC.h"

NSString *const KoeObjCExceptionDomain = @"Koe.ObjCException";

NSError *KoeCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        NSString *reason = e.reason ?: @"";
        return [NSError errorWithDomain:KoeObjCExceptionDomain code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", e.name, reason],
            @"name": e.name,
            @"reason": reason,
        }];
    }
}
