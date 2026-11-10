#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift cannot catch Objective-C exceptions; an uncaught one aborts the app.
/// AVAudioEngine raises them for recoverable conditions (a tap format that no
/// longer matches the device), so those calls run through here.
@interface SabbelObjC : NSObject

/// Runs `block`. An exception it raises comes back as an NSError (domain
/// "SabbelObjCException", the exception's name and reason in the description).
+ (BOOL)catchingException:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
