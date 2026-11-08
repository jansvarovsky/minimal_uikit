// Debug-only script runner: drives the UI from a file. Never linked into release builds.
#import <UIKit/UIKit.h>
static NSArray *lines; static int pc; static NSString *outdir; static NSDate *deadline;
static void logs(NSString *s) {
    NSString *p = [outdir stringByAppendingPathComponent:@"log.txt"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:p]; }
    [h seekToEndOfFile]; [h writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:4]]; [h closeFile];
}
static void walk(UIView *v, NSMutableArray *a) { if (v.hidden || v.alpha < 0.02) return; [a addObject:v]; for (UIView *s in v.subviews) walk(s, a); }
static NSArray *views(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class])
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (!w.hidden) walk(w, a);
    return a;
}
static NSString *textOf(UIView *v) {
    NSString *t = nil;
    if ([v isKindOfClass:UILabel.class]) t = ((UILabel *)v).text;
    else if ([v isKindOfClass:UIButton.class]) t = [(UIButton *)v currentTitle] ?: v.accessibilityLabel;
    else if ([v isKindOfClass:UITextField.class]) { UITextField *f = (id)v; t = f.secureTextEntry ? f.placeholder : (f.text.length ? f.text : f.placeholder); }
    else if ([v isKindOfClass:UITextView.class]) t = ((UITextView *)v).text;
    else t = v.accessibilityLabel;
    return t;
}
static BOOL onscreen(UIView *v) { CGRect r = [v convertRect:v.bounds toView:nil]; return CGRectIntersectsRect(r, v.window.bounds); }
static UIView *find(NSString *q) { for (UIView *v in views()) { NSString *t = textOf(v); if (t && [t containsString:q] && onscreen(v)) return v; } return nil; }
static void shot(NSString *n) {
    UIWindow *w = nil; for (UIView *v in views()) if ([v isKindOfClass:UIWindow.class]) { w = (id)v; break; }
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:w.bounds.size];
    UIImage *i = [r imageWithActions:^(UIGraphicsImageRendererContext *c) { [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO]; }];
    [UIImagePNGRepresentation(i) writeToFile:[outdir stringByAppendingFormat:@"/%@.png", n] atomically:YES];
}
static BOOL tap(NSString *q) {
    UIView *v = find(q); if (!v) return NO;
    for (UIView *p = v; p; p = p.superview) {
        if ([p isKindOfClass:UIControl.class]) { [(UIControl *)p sendActionsForControlEvents:UIControlEventTouchUpInside|UIControlEventPrimaryActionTriggered]; return YES; }
        if ([p isKindOfClass:UITableViewCell.class]) {
            UIView *t = p.superview; while (t && ![t isKindOfClass:UITableView.class]) t = t.superview;
            UITableView *tv = (id)t; NSIndexPath *ip = [tv indexPathForCell:(id)p];
            if (ip) { [tv.delegate tableView:tv didSelectRowAtIndexPath:ip]; return YES; }
        }
    }
    return NO;
}
static NSString *expand(NSString *s) { if ([s hasPrefix:@"$"]) { const char *e = getenv(s.UTF8String + 1); return e ? @(e) : @""; } return s; }
static UIViewController *top(UIViewController *c) {
    if ([c isKindOfClass:UITabBarController.class]) return top(((UITabBarController *)c).selectedViewController);
    if (c.presentedViewController) return top(c.presentedViewController);
    if ([c isKindOfClass:UINavigationController.class]) return top(((UINavigationController *)c).topViewController);
    return c;
}
static UIWindow *win(void) { for (UIView *v in views()) if ([v isKindOfClass:UIWindow.class]) return (id)v; return nil; }
static void fail(NSString *m) { logs([@"FAIL " stringByAppendingString:m]); shot(@"failure"); NSMutableArray *a = [NSMutableArray array]; for (UIView *v in views()) { NSString *t = textOf(v); if (t.length && onscreen(v)) [a addObject:t]; } logs([a componentsJoinedByString:@" | "]); exit(1); }
static void step(NSTimer *t) {
    if (pc >= lines.count) { logs(@"DONE"); exit(0); }
    NSString *l = lines[pc]; NSArray *w = [l componentsSeparatedByString:@"\t"]; NSString *c = w[0];
    NSString *a = w.count > 1 ? expand(w[1]) : @"", *b = w.count > 2 ? expand(w[2]) : @"";
    if (!c.length || [c hasPrefix:@"#"]) { pc++; return; }
    if ([c isEqual:@"expect"] || [c isEqual:@"gone"] || [c isEqual:@"waittap"]) {
        BOOL found = find(a) != nil; BOOL want = ![c isEqual:@"gone"];
        if (found == want) { if ([c isEqual:@"waittap"]) tap(a); logs([NSString stringWithFormat:@"ok %@ %@", c, w[1]]); deadline = nil; pc++; return; }
        if (!deadline) deadline = [NSDate dateWithTimeIntervalSinceNow:b.length ? b.doubleValue : 20];
        if ([deadline timeIntervalSinceNow] < 0) fail(l);
        return;
    }
    if ([c isEqual:@"wait"]) { if (!deadline) deadline = [NSDate dateWithTimeIntervalSinceNow:a.doubleValue]; if ([deadline timeIntervalSinceNow] > 0) return; deadline = nil; pc++; return; }
    pc++;
    if ([c isEqual:@"tap"]) { if (!tap(a)) fail(l); }
    else if ([c isEqual:@"type"]) {
        UIView *v = find(a); if (![v isKindOfClass:UITextField.class] && ![v isKindOfClass:UITextView.class]) fail(l);
        if ([v isKindOfClass:UITextField.class]) { ((UITextField *)v).text = b; [(UIControl *)v sendActionsForControlEvents:UIControlEventEditingChanged]; }
        else { ((UITextView *)v).text = b; [((UITextView *)v).delegate textViewDidChange:(id)v]; }
    }
    else if ([c isEqual:@"shot"]) shot(a);
    else if ([c isEqual:@"tab"]) ((UITabBarController *)win().rootViewController).selectedIndex = a.intValue;
    else if ([c isEqual:@"back"]) { UIViewController *x = top(win().rootViewController); if (x.navigationController.viewControllers.count > 1) [x.navigationController popViewControllerAnimated:NO]; else [x dismissViewControllerAnimated:NO completion:nil]; }
    else if ([c isEqual:@"barbutton"]) { UIViewController *x = top(win().rootViewController); UIBarButtonItem *i = [a isEqual:@"left"] ? x.navigationItem.leftBarButtonItem : x.navigationItem.rightBarButtonItem; if (!i) fail(l); if (i.primaryAction) [i.primaryAction performWithSender:nil target:nil]; else if (i.target) [UIApplication.sharedApplication sendAction:i.action to:i.target from:i forEvent:nil]; else fail(l); }
    else if ([c isEqual:@"scroll"]) { for (UIView *v in views()) if ([v isKindOfClass:UIScrollView.class] && ![v isKindOfClass:UITextView.class] && onscreen(v)) { UIScrollView *s = (id)v; [s setContentOffset:CGPointMake(0, s.contentOffset.y + s.bounds.size.height) animated:NO]; [s layoutIfNeeded]; break; } }
    else if ([c isEqual:@"dump"]) { NSMutableArray *x = [NSMutableArray array]; for (UIView *v in views()) { NSString *s = textOf(v); if (s.length && onscreen(v)) [x addObject:s]; } logs([@"DUMP " stringByAppendingString:[x componentsJoinedByString:@" | "]]); }
    else if ([c isEqual:@"log"]) logs(a);
    else fail([@"unknown command " stringByAppendingString:l]);
}
void ts_test_start(void) {
    const char *s = getenv("TS_SCRIPT"), *o = getenv("TS_OUT"); if (!s || !o) return;
    outdir = [@(o) retain]; [[NSFileManager defaultManager] removeItemAtPath:[outdir stringByAppendingPathComponent:@"log.txt"] error:nil];
    lines = [[[NSString stringWithContentsOfFile:@(s) encoding:4 error:nil] componentsSeparatedByString:@"\n"] retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500000000), dispatch_get_main_queue(), ^{ [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) { step(t); }]; });
}
