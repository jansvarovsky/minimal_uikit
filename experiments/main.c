// Smallest UIKit app: plain C talking to the Objective-C runtime.
// One runtime-built class serves as both app delegate and scene delegate,
// so the binary carries no ObjC metadata and Info.plist needs no scene manifest.
#include <objc/message.h>
#include <objc/runtime.h>

extern int UIApplicationMain(int, char **, void *, void *);

// Call imports through the GOT: no __stubs, no lazy pointers, no __DATA segment.
// The empty asm hides the value so the compiler can't turn it back into a direct call.
#define G(f) ({ void *p_ = (void *)&f; __asm__("" : "+r"(p_)); (__typeof__(&f))p_; })

#ifdef TRACE
#include <unistd.h>
#define T(s) G(write)(2, s "\n", sizeof(s))
#else
#define T(s)
#endif

#define S(s) G(sel_registerName)(s)
#define C(s) ((id)G(objc_getClass)(s))
#define M0 ((id (*)(id, SEL))G(objc_msgSend))
#define M1 ((id (*)(id, SEL, id))G(objc_msgSend))
#define M2 ((id (*)(id, SEL, id, id))G(objc_msgSend))

static id config(id self, SEL _cmd, id app, id session, id opts) {
    T("config");
    id c = M2(C("UISceneConfiguration"), S("configurationWithName:sessionRole:"), 0,
              M0(session, S("role")));
    M1(c, S("setDelegateClass:"), (id)G(object_getClass)(self));
    return c;
}

static void connect(id self, SEL _cmd, id scene, id session, id opts) {
    T("connect");
    id w = M1(M0(C("UIWindow"), S("alloc")), S("initWithWindowScene:"), scene);
    id vc = M0(M0(C("UIViewController"), S("alloc")), S("init"));
    M1(M0(vc, S("view")), S("setBackgroundColor:"), M0(C("UIColor"), S("systemGreenColor")));
    M1(w, S("setRootViewController:"), vc);
    M0(w, S("makeKeyAndVisible")); // w is leaked on purpose: nothing else retains it.
    T("shown");
}

int main(int argc, char **argv) {
    T("main");
    Class c = G(objc_allocateClassPair)(G(objc_getClass)("UIResponder"), "A", 0);
    G(class_addMethod)(c, S("application:configurationForConnectingSceneSession:options:"), (IMP)config, "@@:@@@");
    G(class_addMethod)(c, S("scene:willConnectToSession:options:"), (IMP)connect, "v@:@@@");
    G(class_addProtocol)(c, G(objc_getProtocol)("UISceneDelegate")); // UIKit asserts on this.
    G(objc_registerClassPair)(c);
    return G(UIApplicationMain)(argc, argv, 0, M0((id)c, S("description")));
}
