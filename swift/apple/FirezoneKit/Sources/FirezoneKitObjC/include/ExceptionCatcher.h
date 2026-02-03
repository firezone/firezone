// Source - https://stackoverflow.com/a/35003095
// Posted by Casey, modified by community. See post 'Timeline' for change history
// Retrieved 2026-02-04, License - CC BY-SA 3.0

//
//  ExceptionCatcher.h
//

#import <Foundation/Foundation.h>

NS_INLINE NSException * _Nullable tryObjC(void(^_Nonnull tryBlock)(void)) {
    @try {
        tryBlock();
    }
    @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
