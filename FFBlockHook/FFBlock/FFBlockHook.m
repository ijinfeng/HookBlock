//
//  FFBlockHook.m
//  FFBlockHook
//
//  Created by jinfeng on 2021/6/18.
//

#import "FFBlockHook.h"
#import <mach/vm_map.h>
#import <mach/mach_init.h>
#import <objc/runtime.h>


@interface FFBlockHookDesc : NSObject
@property (nonatomic, assign) FFBlockHookOption option;
@property (nonatomic, copy) id actionBlock;
@end

@implementation FFBlockHookDesc

+ (instancetype)hookDesc:(FFBlockHookOption)option action:(id)actionBlock {
    FFBlockHookDesc *desc = [FFBlockHookDesc new];
    desc.option = option;
    desc.actionBlock = actionBlock;
    return desc;
}

@end

/// 绑定的invoke数组
static const char *k_invokes_bind_key;
/// 绑定的desc对象数组
static const char *k_descs_bind_key;
/// 对同一个block hook的次数
static const char *k_hook_count_bind_key;
/// 回调次数
static const char *k_callback_count_bind_key;


// Block code
// https://opensource.apple.com/source/libclosure/libclosure-67/

// Values for Block_layout->flags to describe block objects
enum {
    BLOCK_DEALLOCATING =      (0x0001),  // runtime
    BLOCK_REFCOUNT_MASK =     (0xfffe),  // runtime
    BLOCK_NEEDS_FREE =        (1 << 24), // runtime
    BLOCK_HAS_COPY_DISPOSE =  (1 << 25), // compiler
    BLOCK_HAS_CTOR =          (1 << 26), // compiler: helpers have C++ code
    BLOCK_IS_GC =             (1 << 27), // runtime
    BLOCK_IS_GLOBAL =         (1 << 28), // compiler
    BLOCK_USE_STRET =         (1 << 29), // compiler: undefined if !BLOCK_HAS_SIGNATURE
    BLOCK_HAS_SIGNATURE  =    (1 << 30), // compiler
    BLOCK_HAS_EXTENDED_LAYOUT=(1 << 31)  // compiler
};

#define BLOCK_DESCRIPTOR_1 1
struct Block_descriptor_1 {
    uintptr_t reserved;
    uintptr_t size;
};

#define BLOCK_DESCRIPTOR_2 1
struct Block_descriptor_2 {
    // requires BLOCK_HAS_COPY_DISPOSE
    void (*copy)(void *dst, const void *src);
    void (*dispose)(const void *);
};

#define BLOCK_DESCRIPTOR_3 1
struct Block_descriptor_3 {
    // requires BLOCK_HAS_SIGNATURE
    const char *signature;
    const char *layout;     // contents depend on BLOCK_HAS_EXTENDED_LAYOUT
};

struct Block_layout {
    void *isa;
    volatile int32_t flags; // contains ref count
    int32_t reserved;
    void (*invoke)(void *, ...);
    struct Block_descriptor_1 *descriptor;
    // imported variables
};


struct Hook_Invoke {
    void (*invoke)(void *, ...);
};

static vm_prot_t changeAddressToWritable(void *address) {
    vm_address_t addr = (vm_address_t)address;
    vm_size_t vmsize = 0;
    mach_port_t object = 0;
#if defined(__LP64__) && __LP64__
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCnt = VM_REGION_BASIC_INFO_COUNT_64;
    kern_return_t ret = vm_region_64(mach_task_self(), &addr, &vmsize, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &infoCnt, &object);
#else
    vm_region_basic_info_data_t info;
    mach_msg_type_number_t infoCnt = VM_REGION_BASIC_INFO_COUNT;
    kern_return_t ret = vm_region(mach_task_self(), &addr, &vmsize, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &infoCnt, &object);
#endif
    if (ret != KERN_SUCCESS) {
        NSLog(@"vm_region block invoke pointer failed! ret:%d, addr:%p", ret, address);
        return VM_PROT_NONE;
    }
    vm_prot_t protection = info.protection;
    if ((protection&VM_PROT_WRITE) == 0) {
        ret = vm_protect(mach_task_self(), (vm_address_t)address, sizeof(address), false, protection|VM_PROT_WRITE);
        if (ret != KERN_SUCCESS) {
            NSLog(@"vm_protect block invoke pointer VM_PROT_WRITE failed! ret:%d, addr:%p", ret, address);
            return VM_PROT_NONE;
        }
    }
    return protection;
}

static bool setOriginProtection(void *address, vm_prot_t originProtection) {
    if (originProtection == VM_PROT_NONE) return false;
    if ((originProtection&VM_PROT_WRITE) == 0) {
        kern_return_t ret = vm_protect(mach_task_self(), (vm_address_t)address, sizeof(address), false, originProtection);
        if (ret != KERN_SUCCESS) {
            return  false;
        }
    }
    return YES;
}

const char *getBlockSignture(struct Block_layout *layout) {
    const char *csignature = NULL;
    void *desc1 = layout->descriptor;
    if (layout->flags & BLOCK_HAS_SIGNATURE) {
        desc1 += sizeof(struct Block_descriptor_1);
        if (layout->flags & BLOCK_HAS_COPY_DISPOSE) {
            desc1 += sizeof(struct Block_descriptor_2);
        }
        csignature = (*(const char **)desc1);
    }
    return csignature;
}

static void _ff_invoke(void *p, ...) {
    id block = (__bridge  id)p;
    struct Block_layout *b = (__bridge struct Block_layout *)block;
    const char *bsignature = getBlockSignture(b);
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:bsignature];
    // 防止无限回调
    bool needReturn = false;
    int hookCount = [objc_getAssociatedObject(block, &k_hook_count_bind_key) intValue];
    int callbackCount = [objc_getAssociatedObject(block, &k_callback_count_bind_key) intValue];
    if (callbackCount > hookCount) {
        callbackCount = 0;
        needReturn = true;
    } else {
        callbackCount += 1;
    }
    objc_setAssociatedObject(block, &k_callback_count_bind_key, @(callbackCount), OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (needReturn) {
        return;
    }
    
    NSMutableArray *descs = objc_getAssociatedObject(block, &k_descs_bind_key);
    FFBlockHookDesc *desc = nil;
    if (callbackCount <= descs.count) {
        desc = descs[callbackCount - 1];
    }
    if (!desc) return;
    
    id actionBlock = desc.actionBlock;
    struct Block_layout *a = (__bridge struct Block_layout *)actionBlock;
    const char *_asignature = getBlockSignture(a);
    NSInvocation *actionInvocation = nil;
    if (_asignature != NULL) {
        NSMethodSignature *asignature = [NSMethodSignature signatureWithObjCTypes:_asignature];
        
        actionInvocation = [NSInvocation invocationWithMethodSignature:asignature];
        actionInvocation.target = actionBlock;
        va_list va;
        va_start(va, p);
        for (int i = 0; i < signature.numberOfArguments - 1; i++) {
            if (i >= asignature.numberOfArguments - 1) {
                break;
            }
            void * arg = va_arg(va, void *);
            [actionInvocation setArgument:&arg atIndex:i+1];
        }
        va_end(va);
    }
    
    if (desc.option & FFBlockHookOptionInstead) {
        // instead
//        NSLog(@"ff_block_hook instead");
        [actionInvocation invoke];
    } else {
        if (desc.option & FFBlockHookOptionBefore) {
//            NSLog(@"ff_block_hook before");
            [actionInvocation invoke];
        }
    
        if (callbackCount == descs.count) { // 最后一次回调才会触发原始block
            void *invokeAddress = &(b->invoke);
            void *originInvoke = (__bridge void *)(objc_getAssociatedObject(block, &k_invokes_bind_key));
            vm_prot_t prot = changeAddressToWritable(invokeAddress);
            b->invoke = originInvoke;
            setOriginProtection(invokeAddress, prot);
        }
        
        if (bsignature != NULL) {
            NSUInteger argsCount = signature.numberOfArguments;
            
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = block;
            
            va_list va;
            va_start(va, p);
            for (int i = 0; i < argsCount - 1; i++) {
                void * arg = va_arg(va, void *);
                [invocation setArgument:&arg atIndex:i+1];
            }
            va_end(va);
            
            [invocation invoke];
        }
        if (desc.option & FFBlockHookOptionAfter) {
//            NSLog(@"ff_block_hook after");
            [actionInvocation invoke];
        }
    }
}


@implementation FFBlockHook

+ (void)hookBlock:(id)block optional:(FFBlockHookOption)option usingCustomAction:(id)actionBlock {
    if (!block || !actionBlock) return;
    
    struct Block_layout *b = (__bridge struct Block_layout *)block;
    if (b->invoke == NULL) {
        return;
    }
    
    int hookCount = [objc_getAssociatedObject(block, &k_hook_count_bind_key) intValue];
    objc_setAssociatedObject(block, &k_hook_count_bind_key, @(hookCount+1), OBJC_ASSOCIATION_COPY_NONATOMIC);
    
    
    if (b->invoke != _ff_invoke) {
        objc_setAssociatedObject(block, &k_invokes_bind_key, (__bridge  id)((void *)(b->invoke)), OBJC_ASSOCIATION_ASSIGN);
        
        void *invokeAddress = &(b->invoke);
        vm_prot_t prot = changeAddressToWritable(invokeAddress);
        b->invoke = _ff_invoke;
        setOriginProtection(invokeAddress, prot);
    }
    
    NSMutableArray *descs = objc_getAssociatedObject(block, &k_descs_bind_key);
    if (!descs) {
        descs = [NSMutableArray array];
    }
    FFBlockHookDesc *desc = [FFBlockHookDesc hookDesc:option action:actionBlock];
    [descs addObject:desc];
    objc_setAssociatedObject(block, &k_descs_bind_key, descs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
