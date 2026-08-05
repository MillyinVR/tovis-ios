// The one thing Swift cannot do for itself: survive an Objective-C exception.
//
// AVFoundation validates device and session writes by raising NSException.
// Swift has no `@catch`, so every such raise is `objc_exception_throw` →
// `std::terminate` → `SIGABRT`: the process dies, with no preview ever drawn
// and nothing the Swift side can do about it. Three builds of this app died
// exactly that way (#273, #275, and again on build 38), each time on a write
// whose arguments had *already* been validated — because the validation and
// the write read the device at two different instants.
//
// Validation can always be raced. Catching cannot. So the app no longer bets
// on getting every precondition right: it wraps the write.
//
// ⚠️ RULES FOR THE BLOCK — these are load-bearing, not style:
//
//   1. The block must contain ONE Objective-C call and nothing else. When the
//      exception unwinds it passes THROUGH the Swift frame that called it, and
//      Swift guarantees no cleanup on that path — `defer` will not run, and
//      anything needing release leaks.
//   2. Never put `defer` inside the block. Put the unlock AFTER the call
//      returns, in the Swift caller, where it runs on both paths.
//   3. Treat a caught exception as "this device write did not happen" — never
//      as "the object is still in a known state".
//
// See `CaptureExceptionShield` for the Swift face of this, which is what app
// code should actually call.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// `userInfo` key carrying the raised `NSException`'s `name`.
extern NSString *const TovisObjCExceptionNameKey;

/// `NSError.domain` for a converted Objective-C exception.
extern NSErrorDomain const TovisObjCExceptionDomain;

@interface TovisObjCException : NSObject

/// Runs `block`, converting any raised `NSException` into `NO` + `error`.
///
/// Returns `YES` when the block completed without raising. `error` carries the
/// exception's `reason` as its localized description and its `name` under
/// `TovisObjCExceptionNameKey`, so a caught throw can be logged specifically
/// rather than as "something went wrong".
///
/// Imported into Swift as a throwing call: `try TovisObjCException.catching { … }`.
+ (BOOL)catching:(NS_NOESCAPE dispatch_block_t)block
           error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(catching(_:));

@end

NS_ASSUME_NONNULL_END
