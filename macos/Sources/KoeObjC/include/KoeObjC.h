#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Runs `block` and returns nil, or the NSException it raised as an NSError.
// Swift cannot catch Objective-C exceptions; without this, an exception from
// AVFAudio (installTapOnBus: with an unusable format, for example) aborts the
// whole process.
NSError * _Nullable KoeCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
