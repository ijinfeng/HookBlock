
### 前言
iOS的方法交换能为我们 hook 实例方法，也能为我们 hook 类方法，但是对于 Block 却无能为力，原因很简单，Block并不是一个方法，而是一个函数指针。但是如果你了解了 Block 底层结构，又熟悉了iOS中的消息转发机制。想要 Hook OC 的Block还是能做到的。有关Hook OC Block的文章有许多，目前有两种比较常见的方法来Hook Block：

* 一种是通过引入 [Libffi](https://github.com/libffi/libffi) ，利用 `Libffi` 在运行时动态定义｜调用函数的强大特性，来实现Block的hook。参考文章 [Hook Objective-C Block with Libffi](http://yulingtianxia.com/blog/2018/02/28/Hook-Objective-C-Block-with-Libffi/)。 这里引用原该方案作者的一段原理说明（感谢）:
> 1. 根据 `block` 对象的签名，使用 `ffi_prep_cif` 构建 `block->invoke` 函数的模板 `cif`
> 2. 使用 `ffi_closure`，根据 `cif` 动态定义函数 `replacementInvoke`，并指定通用的实现函数为 `ClosureFunc`
> 3. 将 `block->invoke` 替换为 `replacementInvoke`，原始的 `block->invoke` 存放在 `originInvoke`
> 4. 在 `ClosureFunc` 中动态调用 `originInvoke` 函数和执行 hook 的逻辑。

* 另一种是通过消息转发的方式，利用 runtime 函数 `_objc_msgForward` 来实现对Block的hook。参考文章 [Block hook 正确姿势？](https://juejin.cn/post/6844903776839532552) 它的原理比较取巧，看一下原作者的原理说明（感谢）：
> 1. 保存原来block的副本，因为不影响原有的微信业务逻辑，在hook注入我们自己业务逻辑之后，我们需要回过头响应原有的微信block逻辑；
> 2. 强制启动block的消息转发机制；
> 3. 在消息转发最后一步，将副本和hook block取出包装成NSInvocation进行调用；

* 第三种方案？
> 那么有没有既不需要用到`Libffi`，又不用方法交换使用`_objc_msgForward`的其他方法呢？答案是有的。[源码跳转](https://github.com/ijinfeng/HookBlock)

### 原理
通过 hook Block的回调函数`invoke(void *p,...)`，替换为我们自定义的回调函数，在这个自定义的回调函数 `_ff_invoke(void *p,...)`内，注入其他逻辑，然后再以OC灵活的消息发送机制 `NSInvocation`去触发原来的block的回调及完成了对Block的hook。


### 实现

> *思考一下?* 要想实现对Block的hook，需要解决以下几点：
> 1. 如何获取block底层的回调函数，并且替换为自己的回调函数
> 2. 如何将block的入参传入到自己的回调中，并触发自己的回调
> 3. 在block的回调被替换后，如何触发原block的回调
> 4. 如何处理hook链导致的回调循环问题

#### 1、获取block底层结构Block_layout

想要获取Block的底层回调函数，首先要知道[Block的底层数据结构](https://opensource.apple.com/source/libclosure/libclosure-67/)。这里直接从源码处节选：
```
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
```
其中 `struct Block_layout` 就是真正的block底层结构，分别存了如下信息：

* **isa**：指向Block具体的类型，`__NSStackBlock__`，`__NSMallockBlock__`，`__NSGlobalBlock__`

* **flags**：定义了下列枚举中的信息，通过 `Block_layout->flags` 获取具体值
```
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
```

* **reserved**：预留字段，作用未知

* **invoke**：block的回调函数指针

* **descriptor**：block的具体描述，这有三个结构体，非别为`Block_descriptor_1，Block_descriptor_2，Block_descriptor_3`，编译器会根据 `falgs` 生成不同结构的 `Block_layout`。


通过如下方式将block强转成底层结构 `Block_layout`。
```
// block为外部传入的block对象
struct Block_layout *b = (__bridge struct Block_layout *)block;
```
看下图，我们想要的block的回调函数就是下面的 `invoke` 指针。

![invoke指针](https://note.youdao.com/yws/public/resource/d1fc5e3d93aa7f9721981b1f10cb99fd/xmlnote/WEBRESOURCEb13f0f0f5771271c7e20b359e965fe83/6243)

#### 2、交换invoke函数的实现

在上一步中，我们转换block为底层结构，获取到了回调函数指针 `invoke`，接下来就是将其替换为我们自定义的回调函数，这样block在执行时会进入我们自定义的函数体内。

```
// iOS 13 后，GlobalBlock 对象所占的内存是只读的，这就导致 Hook 过程中无法对 invoke 函数指针做写操作，直接 crash。
// 首先需要判断下 invoke 指针对应的地址有没有写权限，如果没有写权限则需要提权
vm_prot_t prot = changeAddressToWritable(invokeAddress);
// 将block的回调函数换成自己的，注意参数形式保持一致
b->invoke = _ff_invoke;
setOriginProtection(invokeAddress, prot);
```

内存提权代码实现（[参考](http://yulingtianxia.com/blog/2020/05/30/BlockHook-and-Memory-Safety/)）：
```
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
```

自定义的回调函数，注意参数格式类型保持一致。
```
void _ff_invoke(void *p, ...) {
    //... 
}

```
#### 3、在自定义回调函数中调用原始block的回调函数以及自己注入的逻辑回调

block支持以`NSInvocation`的方式触发，而要做到这种方式则需要先获取到block的函数签名。这样我们才能通过构建出一个`NSInvocation`实例，`+ (NSInvocation *)invocationWithMethodSignature:(NSMethodSignature *)sig;`。

block的方法qianm在哪里获取？我们在回到block的底层结构上，其中有个 `Block_descriptor_3` 的结构体，里面有个 `signature` 的成员变量就是我们要的方法签名。
```
struct Block_descriptor_3 {
    // requires BLOCK_HAS_SIGNATURE
    const char *signature;
    const char *layout;     // contents depend on BLOCK_HAS_EXTENDED_LAYOUT
};
```
但是需要注意一点，`Block_descriptor_3`的生成需要`flgs`中有`BLOCK_HAS_SIGNATURE`，也就是需要满足 `flags & BLOCK_HAS_SIGNATURE` 为**true**。相应的，`Block_descriptor_2`的生成需要`flags`中有`BLOCK_HAS_COPY_DISPOSE`，即满足 `flags & BLOCK_HAS_COPY_DISPOSE`为**true**。

再通过指针偏移的方式来获取到`signture`。

```
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
```
> `csignature = (*(const char **)desc1);` 这段代码略微讲解下，`void *`类型的desc1指针强转成指向`char *`类型的指针，再通过`*`操作符获取到指针指向的值就是`csignature`。

拿到了`signture`后，我们就可以初始化一个`NSMethodSignature`出来，用于进一步创建对象`NSInvocation`。还记得我们是在函数`_ff_invoke(void *p,...)`中吗，外部传入的参数都在 `void *p` 中，那么使用`NSInvocation`发消息的参数、方法签名都全了。主动触发block的方式如下：

```
const char *bsignature = getBlockSignture(b);
NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:bsignature];
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
```

如果需要触发自己注入的block，也是同样的方式，这里不多复述。具体请看[源码](https://github.com/ijinfeng/HookBlock/blob/master/FFBlockHook/FFBlock/FFBlockHook.m)。

#### 4. 如何处理hook链带来的循环回调问题？

其实走到这一步时，一般的block hook已经初步完成了。但是一旦对同一个block多次hook就会出现**回调地狱**，你会发现`__ff_invoke`函数深陷回调不可自拔~

那么如何处理？

还是先思考，我们hook多次后，其实最终触发block时，原block回调只有一次，而自己注入的block逻辑根据hook的次数而定，因此统计一个block的hook次数，当回调次数超过hook次数时，退出`__ff_invoke`函数，这样就避免了回调循环。并且需要注意，我们只有在最后一次的`__ff_invoke`回调中，才触发原始block的回调，也就是将block的`invoke`指针给替换回原来的回调函数。至此，hook链已能正常工作。
```
if (callbackCount == descs.count) { // 最后一次回调才会触发原始block
            void *invokeAddress = &(b->invoke);
            void *originInvoke = (__bridge void *)(objc_getAssociatedObject(block, &k_invokes_bind_key));
            vm_prot_t prot = changeAddressToWritable(invokeAddress);
            b->invoke = originInvoke;
            setOriginProtection(invokeAddress, prot);
        }
```

#### 最终实现效果

执行代码：
```
self.block = ^(int a, int b){
        NSLog(@"=============>");

        NSLog(@"a=%d",a);
        NSLog(@"b=%d",b);

        NSLog(@"+++++ %d",a+b);
    };



    [FFBlockHook hookBlock:self.block optional:FFBlockHookOptionAfter|FFBlockHookOptionBefore usingCustomAction:^(int a,int b, int c, int d) {
        NSLog(@"+++a=%d",a);
        NSLog(@"+++b=%d",b);
        NSLog(@"+++c=%d",c);
        NSLog(@"+++d=%d",d);
    }];
    
    [FFBlockHook hookBlock:self.block optional:FFBlockHookOptionInstead usingCustomAction:^{
        NSLog(@"直接替换");
    }];

    self.block(3,4);
    
    
    
    void (^strBlock) (NSString *, id, int ) = ^(NSString *s,id obj, int i) {
        NSLog(@"=========>");

        NSLog(@"s= %@",s);
        NSLog(@"obj=%@",obj);
        NSLog(@"i=%d",i);
    };



    [FFBlockHook hookBlock:strBlock optional:FFBlockHookOptionBefore usingCustomAction: ^int (NSString *s) {
        
        NSLog(@"第一次hook s=%@",s);
        
        return 10;
    }];
    [FFBlockHook hookBlock:strBlock optional:FFBlockHookOptionBefore usingCustomAction: ^ (void) {

        NSLog(@"第二次对strBlock hook");
    }];
    
    [FFBlockHook hookBlock:strBlock optional:FFBlockHookOptionAfter usingCustomAction: ^ (void) {

        NSLog(@"第3次对strBlock hook");
    }];
    
    [FFBlockHook hookBlock:strBlock optional:FFBlockHookOptionAfter|FFBlockHookOptionBefore usingCustomAction: ^ (void) {

        NSLog(@"第4次对strBlock hook");
    }];
    
    strBlock(@"hehe", @[@"1",@"2"], 10);
    
    
    [FFBlockHook hookBlock:strBlock optional:FFBlockHookOptionAfter usingCustomAction: ^ (void) {

        NSLog(@"第5次对strBlock hook");
    }];
    
    strBlock(@"我的天啊，这名🦅吗", @[], 123456);
```
输出：

> 2021-06-20 22:54:15.175775+0800 FFBlockHook[3501:71203] +++a=3  
> 2021-06-20 22:54:15.175976+0800 FFBlockHook[3501:71203] +++b=4  
> 2021-06-20 22:54:15.176111+0800 FFBlockHook[3501:71203] +++c=0  
> 2021-06-20 22:54:15.176232+0800 FFBlockHook[3501:71203] +++d=0  
> 2021-06-20 22:54:15.176395+0800 FFBlockHook[3501:71203]  直接替换  
> 2021-06-20 22:54:15.176543+0800 FFBlockHook[3501:71203] +++a=3  
> 2021-06-20 22:54:15.176673+0800 FFBlockHook[3501:71203] +++b=4  
> 2021-06-20 22:54:15.176776+0800 FFBlockHook[3501:71203] +++c=0  
> 2021-06-20 22:54:15.176983+0800 FFBlockHook[3501:71203] +++d=0  
> 2021-06-20 22:54:15.177440+0800 FFBlockHook[3501:71203] 第一次hook s=hehe  
> 2021-06-20 22:54:15.177750+0800 FFBlockHook[3501:71203] 第二次对strBlock   hook  
> 2021-06-20 22:54:15.178113+0800 FFBlockHook[3501:71203] 第4次对strBlock hook  
> 2021-06-20 22:54:15.178513+0800 FFBlockHook[3501:71203] =========>  
> 2021-06-20 22:54:15.178926+0800 FFBlockHook[3501:71203] s= hehe  
> 2021-06-20 22:54:15.179344+0800 FFBlockHook[3501:71203] obj=(  
>    1,   
>   2  
> )  
> 2021-06-20 22:54:15.179642+0800 FFBlockHook[3501:71203] i=10    
> 2021-06-20 22:54:15.180030+0800 FFBlockHook[3501:71203] 第4次对strBlock hook  
> 2021-06-20 22:54:15.180423+0800 FFBlockHook[3501:71203] 第3次对strBlock hook  
> 2021-06-20 22:54:15.180934+0800 FFBlockHook[3501:71203] =========>  
> 2021-06-20 22:54:15.235841+0800 FFBlockHook[3501:71203] s=   我的天啊，这名🦅吗  
> 2021-06-20 22:54:15.236076+0800 FFBlockHook[3501:71203] obj=(  
> )  
> 2021-06-20 22:54:15.236221+0800 FFBlockHook[3501:71203] i=123456  
> 2021-06-20 22:54:15.236380+0800 FFBlockHook[3501:71203] 第5次对strBlock hook  

[源码传送门](https://github.com/ijinfeng/HookBlock)

-------
### 参考：

[Block hook 正确姿势？](https://juejin.cn/post/6844903776839532552)

[Hook Objective-C Block with Libffi](http://yulingtianxia.com/blog/2018/02/28/Hook-Objective-C-Block-with-Libffi/)

[MABlockClosure](https://github.com/mikeash/MABlockClosure/tree/master/iPhoneTest)

[BlockHook学习记录](https://www.jianshu.com/p/1e0d31a974af)

[Block签名信息的使用](https://blog.csdn.net/WangErice/article/details/105535708)

 
