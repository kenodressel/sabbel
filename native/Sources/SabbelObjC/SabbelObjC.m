#import "SabbelObjC.h"

@implementation SabbelObjC

+ (BOOL)catchingException:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *description = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
            *error = [NSError errorWithDomain:@"SabbelObjCException"
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return NO;
    }
}

@end
