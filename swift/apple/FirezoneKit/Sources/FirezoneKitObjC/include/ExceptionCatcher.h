// Source - https://stackoverflow.com/a/35003095
// Posted by Casey, modified by community. See post 'Timeline' for change history
// Retrieved 2026-02-04, License - CC BY-SA 3.0

//
//  ExceptionCatcher.h
//
//  Utilities for catching Objective-C exceptions in Swift code.
//

#import <Foundation/Foundation.h>

// Catches Objective-C exceptions and returns them (or nil if no exception)
// Use this when you want to handle exceptions without converting to Swift errors
NS_INLINE NSException * _Nullable tryObjC(__attribute__((noescape)) void(^_Nonnull tryBlock)(void)) {
    @try {
        tryBlock();
    }
    @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

// Backward compatibility alias
#define tryBlock tryObjC
