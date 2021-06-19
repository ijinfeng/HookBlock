//
//  FFBlockHook.h
//  FFBlockHook
//
//  Created by jinfeng on 2021/6/18.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSInteger, FFBlockHookOption) {
    FFBlockHookOptionInstead = 1,
    FFBlockHookOptionBefore = 1 << 1,
    FFBlockHookOptionAfter = 1 << 2,
};

@interface FFBlockHook : NSObject

/// hook一个block对象，通过option配置或替换，或在block执行前插入，或在执行后插入自定义代码块
/// @param block 被hook的block
/// @param option 替换、在前插入、在后插入
/// @param actionBlock 自定义代码块
+ (void)hookBlock:(id)block optional:(FFBlockHookOption)option usingCustomAction:(id)actionBlock;

@end

NS_ASSUME_NONNULL_END
