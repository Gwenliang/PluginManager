// ============================================================
//  QQ Plugin Manager (巨魔注入版插件管理器)
//  零依赖 dylib：注入 QQ 后，通过右下角悬浮球查看
//  QQ.app 内所有已安装/已加载的 dylib 插件（含详情与禁用引导）
//
//  编译：theos（macOS 或 GitHub Actions，见 Makefile / README）
//  注入：巨魔注入器（TrollFools 类）静态注入，无需 libsubstrate
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach-o/arch.h>
#import <libkern/OSByteOrder.h>
#import <dlfcn.h>
#import <sys/stat.h>

#pragma mark - 常量

#define kPMFloatingTag       9527
#define kPMButtonSide        48.0f
#define kPMKnownThirdParty   @[ @"120hz箱子(1).dylib", @"FakeTools(2) (1).dylib", @"QQBaby1.1.5(2) (1).dylib", @"q_theme.dylib", @"libsubstrate.dylib", @"NTQQ_AntiRecall.dylib" ]

#pragma mark - 数据模型

@interface PMDylibInfo : NSObject
@property (nonatomic, strong) NSString *fileName;     // 文件名
@property (nonatomic, strong) NSString *path;         // 绝对路径
@property (nonatomic, strong) NSString *installName;  // LC_ID_DYLIB
@property (nonatomic, strong) NSString *version;      // current_version
@property (nonatomic, strong) NSString *cpuArch;      // arm64 / arm64e / arm64,arm64e
@property (nonatomic, strong) NSMutableArray<NSString *> *dependencies; // LC_LOAD_DYLIB
@property (nonatomic, assign) BOOL loaded;            // 是否被 dyld 加载
@property (nonatomic, assign) BOOL inRoot;            // 位于 QQ.app 根目录（几乎必为第三方注入）
@property (nonatomic, assign) BOOL isSelf;            // 是否本管理插件自身
@end

@implementation PMDylibInfo
@end

#pragma mark - Mach-O 解析（fat / thin 64，兼容大端 fat）

static uint32_t PMSwap(uint32_t v, BOOL swap) {
    return swap ? OSSwapInt32(v) : v;
}

static NSString *PMCPUName(cpu_type_t type, cpu_subtype_t sub) {
    if (type == CPU_TYPE_ARM64) {
        return (sub == CPU_SUBTYPE_ARM64E) ? @"arm64e" : @"arm64";
    }
    if (type == CPU_TYPE_ARM) return @"arm";
    return [NSString stringWithFormat:@"cpu_%u/%u", (unsigned)type, (unsigned)sub];
}

static void PMParseThin(NSData *data, PMDylibInfo *info, BOOL captureArch) {
    if (data.length < sizeof(struct mach_header_64)) return;
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)data.bytes;
    if (hdr->magic != MH_MAGIC_64 && hdr->magic != MH_CIGAM_64) return;
    BOOL swap = (hdr->magic == MH_CIGAM_64);

    if (captureArch) {
        info.cpuArch = PMCPUName((cpu_type_t)PMSwap(hdr->cputype, swap),
                                 (cpu_subtype_t)PMSwap(hdr->cpusubtype, swap));
    }

    uint32_t ncmds = PMSwap(hdr->ncmds, swap);
    const struct load_command *lc = (const struct load_command *)((const char *)hdr + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd     = PMSwap(lc->cmd, swap);
        uint32_t cmdsize = PMSwap(lc->cmdsize, swap);
        if (cmdsize < sizeof(struct load_command)) break;

        if (cmd == LC_ID_DYLIB || cmd == LC_LOAD_DYLIB ||
            cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB) {
            const struct dylib_command *dc = (const struct dylib_command *)lc;
            uint32_t nameOff = PMSwap(dc->dylib.name.offset, swap);
            const char *name = (const char *)dc + nameOff;
            if (nameOff < cmdsize && name) {
                NSString *str = [NSString stringWithUTF8String:name];
                if (cmd == LC_ID_DYLIB) {
                    info.installName = str;
                    uint32_t ver = PMSwap(dc->dylib.current_version, swap);
                    info.version = [NSString stringWithFormat:@"%u.%u.%u",
                                    (ver >> 16) & 0xffff, (ver >> 8) & 0xff, ver & 0xff];
                } else {
                    if (!info.dependencies) info.dependencies = [NSMutableArray array];
                    [info.dependencies addObject:str];
                }
            }
        }
        lc = (const struct load_command *)((const char *)lc + cmdsize);
    }
}

static void PMParseFat(NSData *data, PMDylibInfo *info) {
    if (data.length < sizeof(struct fat_header)) return;
    const struct fat_header *fh = (const struct fat_header *)data.bytes;
    // fat 文件 magic 按大端存储：小端机器读得 FAT_CIGAM（0xbebafeca）→ 字段需 swap
    BOOL bigEndian = (fh->magic == FAT_MAGIC);       // 本机大端（罕见）
    BOOL littleEndian = (fh->magic == FAT_CIGAM);    // iOS 常态
    if (!bigEndian && !littleEndian) return;
    BOOL swap = bigEndian; // 字段与 magic 同端序：大端时小端机需 swap

    uint32_t nfat = PMSwap(fh->nfat_arch, swap);
    if (nfat > 64) nfat = 64;
    NSMutableArray *archs = [NSMutableArray array];
    const struct fat_arch *fa = (const struct fat_arch *)(fh + 1);
    for (uint32_t i = 0; i < nfat; i++) {
        uint32_t off  = PMSwap(fa[i].offset, swap);
        uint32_t size = PMSwap(fa[i].size, swap);
        cpu_type_t ct    = (cpu_type_t)PMSwap(fa[i].cputype, swap);
        cpu_subtype_t cs = (cpu_subtype_t)PMSwap(fa[i].cpusubtype, swap);
        [archs addObject:PMCPUName(ct, cs)];
        if (off + size <= data.length && size >= sizeof(struct mach_header_64)) {
            NSData *slice = [data subdataWithRange:NSMakeRange(off, size)];
            if (!info.installName) {          // 仅首个能解析的 slice 取元数据
                PMParseThin(slice, info, NO);
            }
        }
    }
    info.cpuArch = [archs componentsJoinedByString:@","];
}

#pragma mark - 收集数据

static NSSet<NSString *> *PMLoadedImagePaths(void) {
    NSMutableSet *set = [NSMutableSet set];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *s = [NSString stringWithUTF8String:name];
        if ([s containsString:@".app/"]) {
            [set addObject:s];
        }
    }
    return set;
}

static NSArray<PMDylibInfo *> *PMCollectDylibs(void) {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    const char *selfName = NULL;
    Dl_info di;
    if (dladdr((const void *)&PMCollectDylibs, &di) && di.dli_fname) {
        selfName = di.dli_fname;
    }

    NSMutableArray *result = [NSMutableArray array];
    NSArray *dirs = @[
        bundlePath,
        [bundlePath stringByAppendingPathComponent:@"Frameworks"]
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if (![f hasSuffix:@".dylib"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:f];
            PMDylibInfo *info = [[PMDylibInfo alloc] init];
            info.fileName = f;
            info.path     = full;
            info.inRoot   = [dir isEqualToString:bundlePath];
            if (selfName && strcmp(selfName, full.UTF8String) == 0) info.isSelf = YES;

            NSData *data = [NSData dataWithContentsOfFile:full options:NSDataReadingMappedIfSafe error:nil];
            if (data.length >= 4) {
                uint32_t magic = *(const uint32_t *)data.bytes;
                if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
                    PMParseFat(data, info);
                } else {
                    PMParseThin(data, info, YES);
                }
            }
            if (!info.installName) info.installName = @"(无 LC_ID_DYLIB / 解析失败)";
            [result addObject:info];
        }
    }

    // 加载状态：路径匹配优先，其次文件名匹配（兼容 /private/var 与 /var 差异）
    NSSet *loaded = PMLoadedImagePaths();
    for (PMDylibInfo *info in result) {
        if ([loaded containsObject:info.path] || [loaded containsObject:[info.path stringByStandardizingPath]]) {
            info.loaded = YES;
            continue;
        }
        for (NSString *lp in loaded) {
            if ([lp hasSuffix:info.fileName]) { info.loaded = YES; break; }
        }
    }
    return result;
}

#pragma mark - 悬浮球

@interface PMFloatingButton : UIView
+ (void)install;
@end

@interface PMListViewController : UITableViewController
@property (nonatomic, strong) NSArray<PMDylibInfo *> *rootItems;
@property (nonatomic, strong) NSArray<PMDylibInfo *> *frameworkItems;
@end

@interface PMDetailViewController : UIViewController
@property (nonatomic, strong) PMDylibInfo *info;
@end

@implementation PMFloatingButton

+ (void)install {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
        if (!keyWindow) return;
        if ([keyWindow viewWithTag:kPMFloatingTag]) return;

        CGFloat x = keyWindow.bounds.size.width  - kPMButtonSide - 16;
        CGFloat y = keyWindow.bounds.size.height - kPMButtonSide - 160;
        PMFloatingButton *btn = [[PMFloatingButton alloc]
                                 initWithFrame:CGRectMake(x, y, kPMButtonSide, kPMButtonSide)];
        btn.tag = kPMFloatingTag;
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                               UIViewAutoresizingFlexibleTopMargin;
        [keyWindow addSubview:btn];
    });
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius  = frame.size.width / 2.0f;
        self.layer.masksToBounds = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.72f];
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        self.layer.borderWidth = 1.0f;
        self.layer.shadowColor  = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35f;
        self.layer.shadowRadius  = 4.0f;
        self.layer.shadowOffset  = CGSizeMake(0, 2);

        UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
        label.text = @"管";
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:20];
        label.textAlignment = NSTextAlignmentCenter;
        [self addSubview:label];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(pm_onTap)];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(pm_onPan:)];
        [self addGestureRecognizer:tap];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)pm_onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    UIView *sup = self.superview;
    if (sup) {
        CGFloat half = self.bounds.size.width / 2.0f;
        c.x = MAX(half, MIN(sup.bounds.size.width  - half, c.x));
        c.y = MAX(half, MIN(sup.bounds.size.height - half, c.y));
    }
    self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}

- (void)pm_onTap {
    PMListViewController *list = [[PMListViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];

    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { kw = w; break; }
    }
    if (!kw) kw = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *top = kw.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) {
        top = ((UINavigationController *)top).visibleViewController;
    }
    if (top) {
        [top presentViewController:nav animated:YES completion:nil];
    }
}

@end

#pragma mark - 列表页

@implementation PMListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件管理";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(pm_dismiss)];

    NSArray *all = PMCollectDylibs();
    NSMutableArray *root = [NSMutableArray array];
    NSMutableArray *fw   = [NSMutableArray array];
    for (PMDylibInfo *info in all) {
        if (info.inRoot) [root addObject:info]; else [fw addObject:info];
    }
    // 已加载在前，本工具置顶
    [root sortUsingComparator:^NSComparisonResult(PMDylibInfo *a, PMDylibInfo *b) {
        if (a.isSelf != b.isSelf) return a.isSelf ? NSOrderedAscending : NSOrderedDescending;
        if (a.loaded != b.loaded) return a.loaded ? NSOrderedAscending : NSOrderedDescending;
        return [a.fileName compare:b.fileName];
    }];
    self.rootItems = root;
    self.frameworkItems = fw;
}

- (void)pm_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return [NSString stringWithFormat:@"注入插件 · QQ.app 根目录（%lu）", (unsigned long)self.rootItems.count];
    }
    return [NSString stringWithFormat:@"Frameworks 目录（%lu）", (unsigned long)self.frameworkItems.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"● 绿=已加载 · ○ 灰=未加载 · 本工具标蓝。静态注入插件无法运行时卸载，点击行查看详情与禁用引导。";
    }
    return @"该目录混有 QQ 内置框架与注入物；NTQQ_AntiRecall 若未加载说明主程序未引用它。";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.rootItems.count : self.frameworkItems.count;
}

- (PMDylibInfo *)pm_itemAt:(NSIndexPath *)ip {
    return ip.section == 0 ? self.rootItems[ip.row] : self.frameworkItems[ip.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pm_cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"pm_cell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.numberOfLines = 0;
    }
    PMDylibInfo *info = [self pm_itemAt:ip];
    cell.textLabel.text = info.fileName;
    if (info.isSelf) {
        cell.textLabel.textColor = [UIColor systemBlueColor];
    } else {
        cell.textLabel.textColor = info.loaded ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
    }
    NSString *mark = info.loaded ? @"● 已加载" : @"○ 未加载";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", mark, info.installName];
    cell.detailTextLabel.textColor = info.loaded ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    PMDetailViewController *vc = [PMDetailViewController new];
    vc.info = [self pm_itemAt:ip];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

#pragma mark - 详情页

@implementation PMDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件详情";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:scroll];

    CGFloat y = 16.0f, w = self.view.bounds.size.width - 32.0f;
    void (^addRow)(NSString *, NSString *) = ^(NSString *key, NSString *val) {
        UILabel *k = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 110, 18)];
        k.text = key;
        k.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        k.textColor = [UIColor secondaryLabelColor];
        [scroll addSubview:k];
        UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(130, y - 3, w - 114, 0)];
        v.text = val;
        v.font = [UIFont systemFontOfSize:14];
        v.numberOfLines = 0;
        v.lineBreakMode = NSLineBreakByCharWrapping;
        CGRect f = v.frame;
        f.size.height = [val boundingRectWithSize:CGSizeMake(f.size.width, CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin
                                       attributes:@{NSFontAttributeName: v.font} context:nil].size.height + 4;
        v.frame = f;
        [scroll addSubview:v];
        y += f.size.height + 14;
    };

    PMDylibInfo *info = self.info;
    addRow(@"文件名", info.fileName);
    addRow(@"安装名", info.installName ?: @"-");
    addRow(@"版本", info.version ?: @"-");
    addRow(@"架构", info.cpuArch ?: @"-");
    addRow(@"状态", info.loaded ? @"已加载（dyld 已注入）" : @"未加载（仅安装）");
    addRow(@"路径", info.path ?: @"-");
    if (info.dependencies.count) {
        addRow(@"依赖", [info.dependencies componentsJoinedByString:@"\n"]);
    }

    UIButton *guide = [UIButton buttonWithType:UIButtonTypeSystem];
    guide.frame = CGRectMake(16, y + 4, w, 44);
    [guide setTitle:@"查看禁用引导" forState:UIControlStateNormal];
    guide.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    guide.backgroundColor = [UIColor whiteColor];
    guide.layer.cornerRadius = 10;
    [guide addTarget:self action:@selector(pm_showGuide) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:guide];
    y += 64;

    scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
}

- (void)pm_showGuide {
    PMDylibInfo *info = self.info;
    if (!info.loaded) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"未加载插件"
            message:[NSString stringWithFormat:@"「%@」已安装但未被 dyld 加载（主程序未引用），无需处理。", info.fileName]
            preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
        return;
    }
    NSString *msg = [NSString stringWithFormat:
        @"插件「%@」为静态注入，启动时已被 dyld 加载并执行 hook，运行中无法卸载。\n\n"
        @"如需禁用：\n"
        @"1. 打开巨魔注入器（TrollFools 类）\n"
        @"2. 选择 QQ\n"
        @"3. 从已注入列表移除 %@\n"
        @"4. 重新注入（或在移除前先备份）后重启 QQ\n\n"
        @"提示：不要直接改名/删除 QQ.app 内的 dylib 文件，否则 dyld 加载失败会导致 QQ 无法启动。",
        info.fileName, info.fileName];
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"禁用引导"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"复制插件名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = info.fileName;
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

@end

#pragma mark - 注入入口

static void PMInit(void) __attribute__((constructor));
static void PMInit(void) {
    [PMFloatingButton install];
}
