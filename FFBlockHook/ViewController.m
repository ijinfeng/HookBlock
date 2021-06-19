//
//  ViewController.m
//  FFBlockHook
//
//  Created by jinfeng on 2021/6/18.
//

#import "ViewController.h"
#import "FFBlockHook.h"

@interface ViewController ()
@property (nonatomic, copy) void(^block)(int, int);
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
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
}


@end
