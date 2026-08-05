#import "TovisObjCException.h"

NSString *const TovisObjCExceptionNameKey = @"TovisObjCExceptionName";
NSErrorDomain const TovisObjCExceptionDomain = @"com.tovis.objc-exception";

@implementation TovisObjCException

+ (BOOL)catching:(NS_NOESCAPE dispatch_block_t)block
           error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            // `reason` is the part worth reading — AVFoundation puts the actual
            // constraint in it ("Gains must be within the range…"), which is
            // what tells a future reader WHICH precondition was violated. The
            // name is kept separately so a log line can say both.
            NSString *name = exception.name ?: @"NSException";
            NSString *reason = exception.reason ?: name;
            *error = [NSError errorWithDomain:TovisObjCExceptionDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason,
                                         TovisObjCExceptionNameKey: name,
                                     }];
        }
        return NO;
    }
}

@end
