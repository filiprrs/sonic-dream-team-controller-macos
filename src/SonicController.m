// SPDX-License-Identifier: MIT
// Copyright (c) 2026 filiprrs
// USB/GIP protocol reference: golden-narwhal12/xbox-controller-driver-macos.
// See THIRD_PARTY_NOTICES.md for attribution.

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <libusb.h>
#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
#include <assert.h>

// Override only for devices that implement the same Xbox One GIP packet format.
#ifndef CONTROLLER_VID
#define CONTROLLER_VID 0x20d6
#endif
#ifndef CONTROLLER_PID
#define CONTROLLER_PID 0xa01a
#endif

static atomic_bool running=true, focused=false, allowed=false, paused=false;
static atomic_bool menuOpen=false;
static atomic_bool navigationMode=false;
static atomic_int deviceState=0, packets=0;
static atomic_int postedEvents=0;
static atomic_int mouseSpeed=900, action[12];
static atomic_bool invertMouse=false;
static CGEventSourceRef mouseSource;
static bool serbian=false;
static NSString *L(NSString *en,NSString *sr){return serbian?sr:en;}
static CGPoint clampPointer(CGPoint p) {
  CGDirectDisplayID displays[32];uint32_t count=0;
  CGGetActiveDisplayList(32,displays,&count);
  double best=INFINITY;CGPoint closest=p;
  for(uint32_t i=0;i<count;i++) {
    CGRect r=CGDisplayBounds(displays[i]);
    CGPoint q=CGPointMake(fmax(CGRectGetMinX(r),fmin(p.x,CGRectGetMaxX(r)-1)),fmax(CGRectGetMinY(r),fmin(p.y,CGRectGetMaxY(r)-1)));
    double d=hypot(q.x-p.x,q.y-p.y);if(d<best){best=d;closest=q;}
  }
  return closest;
}
// A, B, X, Y, LB, RB, L3, R3, View, Menu, LT, RT; -2/-3/-4 = mouse, -5 = pointer.
static const int defaultActions[12]={49,14,56,6,59,58,48,-4,-5,53,-3,-2};
static bool held[128];
static bool mouseHeld[3];
static void applyOutput(const bool next[128],const bool mouse[3]) {
  CGEventFlags flags=0;
  if(next[56])flags|=kCGEventFlagMaskShift;
  if(next[59])flags|=kCGEventFlagMaskControl;
  if(next[58])flags|=kCGEventFlagMaskAlternate;
  for(int k=0;k<128;k++) if(held[k]!=next[k]) {
    CGEventRef e=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)k,next[k]);
    if(e){CGEventSetFlags(e,flags);CGEventPost(kCGHIDEventTap,e);atomic_fetch_add(&postedEvents,1);CFRelease(e);}held[k]=next[k];
  }
  for(int i=0;i<3;i++)if(mouseHeld[i]!=mouse[i]) {
    CGEventRef pos=CGEventCreate(NULL);CGPoint p=pos?CGEventGetLocation(pos):CGPointZero;if(pos)CFRelease(pos);
    CGEventType down[]={kCGEventLeftMouseDown,kCGEventRightMouseDown,kCGEventOtherMouseDown};
    CGEventType up[]={kCGEventLeftMouseUp,kCGEventRightMouseUp,kCGEventOtherMouseUp};
    CGEventRef e=CGEventCreateMouseEvent(atomic_load(&navigationMode)?mouseSource:NULL,mouse[i]?down[i]:up[i],p,(CGMouseButton)i);
    if(e){CGEventPost(kCGHIDEventTap,e);atomic_fetch_add(&postedEvents,1);CFRelease(e);}mouseHeld[i]=mouse[i];
  }
}
static void releaseKeys(void){bool empty[128]={0},mouse[3]={0};applyOutput(empty,mouse);}
static int16_t s16(const unsigned char *p){return (int16_t)((unsigned)p[0]|((unsigned)p[1]<<8));}
static double seconds(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static double axisSpeed(int value){double n=fabs((double)value)/32768.0;if(n<=0.2)return 0;return copysign(pow((n-0.2)/0.8,1.65),value);}
static void moveMouse(int x,int y,double dt) {
  static double remainderX=0,remainderY=0;
  double vx=axisSpeed(x),vy=-axisSpeed(y);if(atomic_load(&invertMouse))vy=-vy;
  if(vx==0)remainderX=0;if(vy==0)remainderY=0;
  int speed=atomic_load(&mouseSpeed);
  remainderX+=vx*speed*dt;remainderY+=vy*speed*dt;
  int dx=(int)remainderX,dy=(int)remainderY;remainderX-=dx;remainderY-=dy;if(!dx&&!dy)return;
  CGEventRef pos=CGEventCreate(NULL);CGPoint p=pos?CGEventGetLocation(pos):CGPointZero;if(pos)CFRelease(pos);p.x+=dx;p.y+=dy;
  if(atomic_load(&navigationMode)){p=clampPointer(p);CGWarpMouseCursorPosition(p);}
  CGEventType type=mouseHeld[0]?kCGEventLeftMouseDragged:mouseHeld[1]?kCGEventRightMouseDragged:mouseHeld[2]?kCGEventOtherMouseDragged:kCGEventMouseMoved;
  CGMouseButton button=mouseHeld[1]?kCGMouseButtonRight:mouseHeld[2]?kCGMouseButtonCenter:kCGMouseButtonLeft;
  // Preserve the original gameplay event source; HID source is only for the visible pointer.
  CGEventRef e=CGEventCreateMouseEvent(atomic_load(&navigationMode)?mouseSource:NULL,type,p,button);
  if(e){CGEventSetIntegerValueField(e,kCGMouseEventDeltaX,dx);CGEventSetIntegerValueField(e,kCGMouseEventDeltaY,dy);CGEventPost(kCGHIDEventTap,e);CFRelease(e);}
}
static void bindAction(int idx,bool active,bool keys[128],bool mouse[3]) {
  if(!active)return;int code=atomic_load(&action[idx]);
  if(code>=0&&code<128)keys[code]=true;
  else if(code<=-2&&code>=-4)mouse[-code-2]=true;
}
static void mapState(unsigned buttons,int x,int y,int lt,int rt,bool keys[128],bool mouse[3]) {
  keys[0]=x< -8000;keys[2]=x>8000;keys[13]=y>8000;keys[1]=y< -8000;
  unsigned masks[]={0x10,0x20,0x40,0x80,0x1000,0x2000,0x4000,0x8000,0x08,0x04};
  for(int i=0;i<10;i++) {
    bindAction(i,(buttons&masks[i])!=0,keys,mouse);
  }
  bindAction(10,lt>256,keys,mouse);bindAction(11,rt>256,keys,mouse);
}
static void *readController(void *unused) {
  (void)unused;mouseSource=CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  if(mouseSource)CGEventSourceSetLocalEventsSuppressionInterval(mouseSource,0);
  libusb_context *ctx=NULL;
  if(libusb_init(&ctx)){atomic_store(&deviceState,-1);if(mouseSource)CFRelease(mouseSource);return NULL;}
  while(atomic_load(&running)) {
    libusb_device_handle *h=libusb_open_device_with_vid_pid(ctx,CONTROLLER_VID,CONTROLLER_PID);
    if(!h){atomic_store(&deviceState,0);usleep(500000);continue;}
    if(libusb_claim_interface(h,0)){libusb_close(h);atomic_store(&deviceState,-1);usleep(500000);continue;}
    struct libusb_config_descriptor *cfg=NULL;unsigned char in=0,out=0;
    if(!libusb_get_active_config_descriptor(libusb_get_device(h),&cfg)) {
      if(!cfg->bNumInterfaces||!cfg->interface[0].num_altsetting){libusb_free_config_descriptor(cfg);libusb_release_interface(h,0);libusb_close(h);atomic_store(&deviceState,-1);usleep(500000);continue;}
      const struct libusb_interface_descriptor *it=&cfg->interface[0].altsetting[0];
      for(int i=0;i<it->bNumEndpoints;i++) {
        if((it->endpoint[i].bmAttributes&3)==3) {
          if(it->endpoint[i].bEndpointAddress&0x80)in=it->endpoint[i].bEndpointAddress;else out=it->endpoint[i].bEndpointAddress;
        }
      }
      libusb_free_config_descriptor(cfg);
    }
    if(!in||!out){libusb_release_interface(h,0);libusb_close(h);atomic_store(&deviceState,-1);usleep(500000);continue;}
    // Power on, LED on, and finish authentication for the tested receiver.
    unsigned char init[][7]={{5,0x20,0,1,0},{10,0x20,1,3,0,1,0x14},{6,0x20,2,2,1,0}};
    int sizes[]={5,7,6},n=0;bool ok=true;
    for(int i=0;i<3;i++){if(libusb_interrupt_transfer(h,out,init[i],sizes[i],&n,500))ok=false;usleep(50000);}
    if(!ok){libusb_release_interface(h,0);libusb_close(h);atomic_store(&deviceState,-1);usleep(500000);continue;}
    atomic_store(&deviceState,1);
    unsigned buttons=0;int x=0,y=0,rx=0,ry=0,lt=0,rt=0;bool haveState=false;unsigned previousButtons=0;double last=seconds();
    while(atomic_load(&running)) {
      unsigned char b[128];n=0;
      int r=libusb_interrupt_transfer(h,in,b,sizeof b,&n,16);
      if(r&&r!=LIBUSB_ERROR_TIMEOUT)break;
      if(!r&&n>=4) {
        if(b[1]&0x10){unsigned char ack[13]={1,0x20,b[2],9,0,b[0],b[1],b[3],0};int sent=0;libusb_interrupt_transfer(h,out,ack,sizeof ack,&sent,200);}
        // GIP 0x20 input: buttons, triggers, then signed 16-bit stick axes.
        if(b[0]==0x20&&n>=18) {
          atomic_fetch_add(&packets,1);buttons=(unsigned)b[4]|((unsigned)b[5]<<8);
          x=s16(b+10);y=s16(b+12);rx=s16(b+14);ry=s16(b+16);
          lt=(unsigned)b[6]|((unsigned)b[7]<<8);rt=(unsigned)b[8]|((unsigned)b[9]<<8);haveState=true;
        }
      }
      double now=seconds(),dt=fmin(now-last,0.05);last=now;
      if(haveState&&atomic_load(&focused)&&atomic_load(&allowed)&&!atomic_load(&paused)&&!atomic_load(&menuOpen)) {
        unsigned pressed=buttons&~previousButtons;
        if(((pressed&0x04)&&atomic_load(&action[9])==53)||((pressed&0x08)&&atomic_load(&action[8])==-5)) {
          bool entering=!atomic_load(&navigationMode);atomic_store(&navigationMode,entering);
          if(entering){CGRect r=CGDisplayBounds(CGMainDisplayID());CGWarpMouseCursorPosition(CGPointMake(CGRectGetMidX(r),CGRectGetMidY(r)));}
        }
        bool keys[128]={0},mouse[3]={0};mapState(buttons,x,y,lt,rt,keys,mouse);applyOutput(keys,mouse);moveMouse(rx,ry,dt);
      }else releaseKeys();
      previousButtons=buttons;
    }
    releaseKeys();atomic_store(&deviceState,0);libusb_release_interface(h,0);libusb_close(h);
  }
  releaseKeys();libusb_exit(ctx);if(mouseSource)CFRelease(mouseSource);return NULL;
}

@interface SonicController : NSObject <NSApplicationDelegate,NSMenuDelegate>
@property NSStatusItem *item;
@property NSMenuItem *stateItem;
@property NSMenuItem *pauseItem;
@property NSTimer *timer;
@property pthread_t thread;
@property BOOL threadStarted;
@property NSMutableArray<NSMenu *> *actionMenus;
@property NSMenuItem *invertItem;
@property NSWindow *pointerWindow;
@end
@implementation SonicController
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  (void)n;self.item=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];self.item.button.title=@"🎮 Sonic";
  [self rebuildMenu];
  NSCursor *cursor=NSCursor.arrowCursor;NSImage *image=cursor.image;
  self.pointerWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,image.size.width,image.size.height) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  self.pointerWindow.opaque=NO;self.pointerWindow.backgroundColor=NSColor.clearColor;self.pointerWindow.hasShadow=NO;self.pointerWindow.ignoresMouseEvents=YES;
  self.pointerWindow.level=NSStatusWindowLevel+1;self.pointerWindow.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
  NSImageView *view=[[NSImageView alloc] initWithFrame:self.pointerWindow.contentView.bounds];view.image=image;self.pointerWindow.contentView=view;
  self.timer=[NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
  pthread_t t;int result=pthread_create(&t,NULL,readController,NULL);
  if(!result){self.thread=t;self.threadStarted=YES;}else atomic_store(&deviceState,-1);
  [self tick:nil];
}
- (void)rebuildMenu {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMenuDidEndTrackingNotification object:self.item.menu];
  NSMenu *m=[NSMenu new];m.delegate=self;self.stateItem=[[NSMenuItem alloc] initWithTitle:L(@"Connecting…",@"Povezivanje…") action:nil keyEquivalent:@""];[m addItem:self.stateItem];
  [m addItem:[NSMenuItem separatorItem]];
  for(NSString *title in @[L(@"Left stick → WASD",@"Levi stik → WASD"),L(@"Right stick → mouse / camera",@"Desni stik → miš / kamera"),L(@"A → Space (jump)",@"A → Space (skok)"),L(@"X → Shift (boost / dash) · RT → left click",@"X → Shift (boost / dash) · RT → levi klik"),L(@"B → E (interact)",@"B → E (interakcija)"),L(@"Y → Z (skip) · R3 → middle click",@"Y → Z (preskakanje) · R3 → srednji klik"),L(@"Menu → pause / pointer · View → pointer on/off",@"Menu → pauza / pokazivač · View → pokazivač uklj./isklj.")]) [m addItem:[[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""]];
  self.actionMenus=[NSMutableArray new];
  NSMenuItem *custom=[[NSMenuItem alloc] initWithTitle:L(@"Button mapping",@"Podesi dugmad") action:nil keyEquivalent:@""];NSMenu *customMenu=[NSMenu new];custom.submenu=customMenu;[m addItem:custom];
  NSArray *labels=@[@"A",@"B",@"X",@"Y",@"LB",@"RB",@"L3",@"R3",@"View",@"Menu",@"LT",@"RT"];
  NSArray *codes=@[@49,@56,@36,@53,@48,@59,@58,@13,@0,@1,@2,@12,@14,@15,@3,@8,@9,@7,@6,@11,@18,@19,@20,@21,@123,@124,@126,@125,@(-2),@(-3),@(-4),@(-5),@(-1)];
  NSArray *names=@[@"Space",@"Shift",@"Enter",@"Escape",@"Tab",@"Control",@"Option",@"W",@"A",@"S",@"D",@"Q",@"E",@"R",@"F",@"C",@"V",@"X",@"Z",@"B",@"1",@"2",@"3",@"4",L(@"Left arrow",@"Strelica levo"),L(@"Right arrow",@"Strelica desno"),L(@"Up arrow",@"Strelica gore"),L(@"Down arrow",@"Strelica dole"),L(@"Left click",@"Levi klik"),L(@"Right click",@"Desni klik"),L(@"Middle click",@"Srednji klik"),L(@"Show / hide pointer",@"Prikaži / sakrij pokazivač"),L(@"Disabled",@"Isključeno")];
  for(int i=0;i<12;i++) {
    NSMenuItem *parent=[[NSMenuItem alloc] initWithTitle:labels[i] action:nil keyEquivalent:@""];NSMenu *sub=[NSMenu new];parent.submenu=sub;[customMenu addItem:parent];[self.actionMenus addObject:sub];
    for(NSUInteger j=0;j<codes.count;j++) {
      if([codes[j] intValue]==-5&&i!=8)continue; // Only View toggles the pointer.
      NSMenuItem *choice=[[NSMenuItem alloc] initWithTitle:names[j] action:@selector(changeAction:) keyEquivalent:@""];choice.target=self;choice.representedObject=@[@(i),codes[j]];choice.state=[codes[j] intValue]==atomic_load(&action[i])?NSControlStateValueOn:NSControlStateValueOff;[sub addItem:choice];
    }
  }
  NSMenuItem *camera=[[NSMenuItem alloc] initWithTitle:L(@"Camera sensitivity",@"Osetljivost kamere") action:nil keyEquivalent:@""];NSMenu *cameraMenu=[NSMenu new];camera.submenu=cameraMenu;[m addItem:camera];
  NSArray *speeds=@[@350,@900,@1600];NSArray *speedNames=@[L(@"Slow",@"Sporo"),L(@"Normal",@"Normalno"),L(@"Fast",@"Brzo")];
  for(NSUInteger i=0;i<speeds.count;i++){NSMenuItem *s=[[NSMenuItem alloc] initWithTitle:speedNames[i] action:@selector(changeSpeed:) keyEquivalent:@""];s.target=self;s.tag=[speeds[i] intValue];s.state=s.tag==atomic_load(&mouseSpeed)?NSControlStateValueOn:NSControlStateValueOff;[cameraMenu addItem:s];}
  self.invertItem=[[NSMenuItem alloc] initWithTitle:L(@"Invert camera up/down",@"Obrni kameru gore/dole") action:@selector(changeInvert:) keyEquivalent:@""];self.invertItem.target=self;self.invertItem.state=atomic_load(&invertMouse)?NSControlStateValueOn:NSControlStateValueOff;[m addItem:self.invertItem];
  NSMenuItem *language=[[NSMenuItem alloc] initWithTitle:L(@"Language",@"Jezik") action:nil keyEquivalent:@""];NSMenu *languageMenu=[NSMenu new];language.submenu=languageMenu;[m addItem:language];
  for(NSString *code in @[@"en",@"sr"]) {
    NSMenuItem *choice=[[NSMenuItem alloc] initWithTitle:[code isEqualToString:@"en"]?@"English":@"Srpski" action:@selector(changeLanguage:) keyEquivalent:@""];choice.target=self;choice.representedObject=code;choice.state=([code isEqualToString:@"sr"]==serbian)?NSControlStateValueOn:NSControlStateValueOff;[languageMenu addItem:choice];
  }
  [m addItem:[NSMenuItem separatorItem]];
  NSMenuItem *p=[[NSMenuItem alloc] initWithTitle:L(@"Allow keyboard and mouse control…",@"Dozvoli upravljanje tastaturom…") action:@selector(permission:) keyEquivalent:@""];p.target=self;[m addItem:p];
  self.pauseItem=[[NSMenuItem alloc] initWithTitle:L(@"Pause controller",@"Pauziraj most") action:@selector(toggle:) keyEquivalent:@""];self.pauseItem.target=self;[m addItem:self.pauseItem];
  NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:L(@"Quit",@"Zatvori") action:@selector(quit:) keyEquivalent:@"q"];quit.target=self;[m addItem:quit];self.item.menu=m;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(menuTrackingEnded:) name:NSMenuDidEndTrackingNotification object:m];
  [self tick:nil];
}
- (void)changeLanguage:(NSMenuItem *)sender {
  serbian=[sender.representedObject isEqualToString:@"sr"];
  [NSUserDefaults.standardUserDefaults setObject:sender.representedObject forKey:@"language"];
  [self performSelector:@selector(rebuildMenu) withObject:nil afterDelay:0];
}
- (void)menuWillOpen:(NSMenu *)menu{(void)menu;atomic_store(&menuOpen,true);}
- (void)menuDidClose:(NSMenu *)menu{(void)menu;atomic_store(&menuOpen,false);}
- (void)menuTrackingEnded:(NSNotification *)note{(void)note;atomic_store(&menuOpen,false);}
- (void)changeAction:(NSMenuItem *)sender {
  NSArray *info=sender.representedObject;int idx=[info[0] intValue],code=[info[1] intValue];atomic_store(&action[idx],code);
  [NSUserDefaults.standardUserDefaults setInteger:code forKey:[NSString stringWithFormat:@"action.%d",idx]];
  for(NSMenuItem *item in self.actionMenus[idx].itemArray)item.state=item==sender?NSControlStateValueOn:NSControlStateValueOff;
}
- (void)changeSpeed:(NSMenuItem *)sender {
  atomic_store(&mouseSpeed,(int)sender.tag);[NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"mouseSpeed"];
  for(NSMenuItem *item in sender.menu.itemArray)item.state=item==sender?NSControlStateValueOn:NSControlStateValueOff;
}
- (void)changeInvert:(id)sender {
  (void)sender;BOOL value=!atomic_load(&invertMouse);atomic_store(&invertMouse,value);[NSUserDefaults.standardUserDefaults setBool:value forKey:@"invertMouse"];self.invertItem.state=value?NSControlStateValueOn:NSControlStateValueOff;
}
- (void)tick:(NSTimer *)timer {
  (void)timer;BOOL trusted=AXIsProcessTrusted();atomic_store(&allowed,trusted);
  NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
  NSString *name=[[front.localizedName ?: @"" stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
  NSString *appName=[[front.bundleURL.lastPathComponent ?: @"" stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
  BOOL sonic=[front.bundleIdentifier isEqualToString:@"com.sega.sdt"]||[name isEqualToString:@"sonicdreamteam"]||[appName isEqualToString:@"sonicdreamteam.app"];
  atomic_store(&focused,sonic);
  self.pauseItem.title=atomic_load(&paused)?L(@"Resume controller",@"Nastavi most"):L(@"Pause controller",@"Pauziraj most");
  if(sonic&&trusted&&atomic_load(&navigationMode)&&!atomic_load(&paused)&&!atomic_load(&menuOpen)&&atomic_load(&deviceState)==1) {
    CGEventRef event=CGEventCreate(NULL);CGPoint point=event?CGEventGetLocation(event):CGPointZero;if(event)CFRelease(event);
    NSCursor *cursor=NSCursor.arrowCursor;CGFloat height=NSScreen.screens.firstObject.frame.size.height;
    [self.pointerWindow setFrameOrigin:NSMakePoint(point.x-cursor.hotSpot.x,height-point.y-(cursor.image.size.height-cursor.hotSpot.y))];[self.pointerWindow orderFrontRegardless];
  }else [self.pointerWindow orderOut:nil];
  int state=atomic_load(&deviceState);
  if(atomic_load(&paused))self.stateItem.title=L(@"Controller paused",@"Most je pauziran");
  else if(state==0)self.stateItem.title=L(@"Waiting for USB receiver",@"Čekam USB dongle");
  else if(state<0)self.stateItem.title=L(@"Cannot open USB receiver",@"Ne mogu da otvorim dongle");
  else if(!trusted)self.stateItem.title=L(@"Accessibility permission required",@"Potrebna dozvola pristupačnosti");
  else if(!sonic)self.stateItem.title=L(@"Ready — open Sonic Dream Team",@"Spremno — otvori Sonic Dream Team");
  else self.stateItem.title=[NSString stringWithFormat:L(@"Active in Sonic · packets: %d",@"Aktivno u Sonicu · paketa: %d"),atomic_load(&packets)];
  [NSUserDefaults.standardUserDefaults setObject:@{@"usb":@(state),@"trusted":@(trusted),@"focused":@(sonic),@"paused":@(atomic_load(&paused)),@"menuOpen":@(atomic_load(&menuOpen)),@"pointerMode":@(atomic_load(&navigationMode)),@"language":serbian?@"sr":@"en",@"packets":@(atomic_load(&packets)),@"postedEvents":@(atomic_load(&postedEvents)),@"timestamp":@(NSDate.date.timeIntervalSince1970)} forKey:@"bridgeStatus"];
}
- (void)permission:(id)sender {
  (void)sender;NSDictionary *options=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)toggle:(id)sender{(void)sender;BOOL p=!atomic_load(&paused);atomic_store(&paused,p);self.pauseItem.title=p?L(@"Resume controller",@"Nastavi most"):L(@"Pause controller",@"Pauziraj most");}
- (void)quit:(id)sender{(void)sender;[NSApp terminate:nil];}
- (void)applicationWillTerminate:(NSNotification *)n{(void)n;atomic_store(&running,false);if(self.threadStarted)pthread_join(self.thread,NULL);}
@end
int main(int argc,const char *argv[]) {
  for(int i=0;i<12;i++)atomic_store(&action[i],defaultActions[i]);
  if(argc>1&&!strcmp(argv[1],"--self-test")) {
    assert(axisSpeed(0)==0);assert(axisSpeed(6000)==0);assert(axisSpeed(32767)>0.99);assert(axisSpeed(-32768)==-1);
    bool keys[128]={0},mouse[3]={0};mapState(0x10|0x40,20000,20000,0,0,keys,mouse);
    assert(keys[49]&&!keys[126]&&!mouse[0]&&keys[56]&&keys[2]&&keys[13]&&!keys[123]&&!keys[124]);
    memset(keys,0,sizeof keys);mapState(0x400,-20000,-20000,1000,1000,keys,mouse);assert(keys[0]&&keys[1]&&!keys[123]&&!keys[56]&&mouse[0]&&mouse[1]);
    memset(keys,0,sizeof keys);memset(mouse,0,sizeof mouse);mapState(0x20|0x04|0x08,0,0,0,0,keys,mouse);assert(keys[14]&&keys[53]&&!keys[36]&&!keys[56]);
    memset(keys,0,sizeof keys);memset(mouse,0,sizeof mouse);mapState(0x80|0x8000,0,0,0,0,keys,mouse);assert(keys[6]&&mouse[2]);
    atomic_store(&navigationMode,true);memset(keys,0,sizeof keys);memset(mouse,0,sizeof mouse);mapState(0x10|0x20,0,0,0,0,keys,mouse);assert(keys[49]&&keys[14]&&!keys[36]&&!keys[53]&&!keys[126]);
    atomic_store(&action[0],126);memset(keys,0,sizeof keys);mapState(0x10,0,0,0,0,keys,mouse);assert(keys[126]&&!keys[36]&&!keys[49]);atomic_store(&action[0],49);atomic_store(&navigationMode,false);
    memset(keys,0,sizeof keys);memset(mouse,0,sizeof mouse);mapState(0x100|0x200|0x400|0x800,0,0,0,0,keys,mouse);
    for(int i=0;i<128;i++)assert(!keys[i]);for(int i=0;i<3;i++)assert(!mouse[i]);
    puts("PASS: WASD, A Space jump, dash, disabled D-pad, triggers, menu controls and camera axes");return 0;
  }
  @autoreleasepool {
    NSUserDefaults *prefs=NSUserDefaults.standardUserDefaults;
    for(int i=0;i<12;i++){NSString *key=[NSString stringWithFormat:@"action.%d",i];if([prefs objectForKey:key])atomic_store(&action[i],(int)[prefs integerForKey:key]);}
    if([prefs objectForKey:@"mouseSpeed"])atomic_store(&mouseSpeed,(int)[prefs integerForKey:@"mouseSpeed"]);atomic_store(&invertMouse,[prefs boolForKey:@"invertMouse"]);
    if(atomic_load(&mouseSpeed)>1600){atomic_store(&mouseSpeed,1600);[prefs setInteger:1600 forKey:@"mouseSpeed"];}
    serbian=[[prefs stringForKey:@"language"] isEqualToString:@"sr"];
    if([NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier].count>1)return 0;
    NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];SonicController *d=[SonicController new];app.delegate=d;[app run];
  }
  return 0;
}
