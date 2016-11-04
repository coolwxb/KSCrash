//
//  KSCrash.m
//
//  Created by Karl Stenerud on 2012-01-28.
//
//  Copyright (c) 2012 Karl Stenerud. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall remain in place
// in this source code.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//


#import "KSCrashAdvanced.h"

#import "KSCrashC.h"
#import "KSCrashCallCompletion.h"
#import "KSCrashState.h"
#import "KSJSONCodecObjC.h"
#import "KSSingleton.h"
#import "NSError+SimpleConstructor.h"
#import "KSSystemCapabilities.h"
#import "KSCrashReportFields.h"
#import "NSDictionary+Merge.h"
#import "KSJSONCodecObjC.h"
#import "RFC3339UTFString.h"
#import "NSString+Demangle.h"
#import "KSCrashDoctor.h"

//#define KSLogger_LocalLevel TRACE
#import "KSLogger.h"

#if KSCRASH_HAS_UIKIT
#import <UIKit/UIKit.h>
#endif


// ============================================================================
#pragma mark - Default Constants -
// ============================================================================

/** The directory under "Caches" to store the crash reports. */
#ifndef KSCRASH_DefaultReportFilesDirectory
    #define KSCRASH_DefaultReportFilesDirectory @"KSCrashReports"
#endif


// ============================================================================
#pragma mark - Constants -
// ============================================================================

#define kCrashLogFilenameSuffix "-CrashLog.txt"
#define kCrashStateFilenameSuffix "-CrashState.json"


// ============================================================================
#pragma mark - Globals -
// ============================================================================

@interface KSCrash ()

@property(nonatomic,readwrite,retain) NSString* bundleName;
@property(nonatomic,readwrite,retain) NSString* nextCrashID;
@property(nonatomic,readwrite,retain) NSString* stateFilePath;

// Mirrored from KSCrashAdvanced.h to provide ivars
@property(nonatomic,readwrite,retain) id<KSCrashReportFilter> sink;
@property(nonatomic,readwrite,retain) NSString* logFilePath;
@property(nonatomic,readwrite,assign) KSReportWriteCallback onCrash;
@property(nonatomic,readwrite,assign) bool printTraceToStdout;
@property(nonatomic,readwrite,assign) KSCrashDemangleLanguage demangleLanguages;
@property(nonatomic,readwrite,retain) NSString* reportsPath;
@property(nonatomic,readwrite,retain) NSString* dataPath;

@end


@implementation KSCrash

// ============================================================================
#pragma mark - Properties -
// ============================================================================

@synthesize sink = _sink;
@synthesize userInfo = _userInfo;
@synthesize deleteBehaviorAfterSendAll = _deleteBehaviorAfterSendAll;
@synthesize handlingCrashTypes = _handlingCrashTypes;
@synthesize deadlockWatchdogInterval = _deadlockWatchdogInterval;
@synthesize printTraceToStdout = _printTraceToStdout;
@synthesize onCrash = _onCrash;
@synthesize bundleName = _bundleName;
@synthesize logFilePath = _logFilePath;
@synthesize nextCrashID = _nextCrashID;
@synthesize searchThreadNames = _searchThreadNames;
@synthesize searchQueueNames = _searchQueueNames;
@synthesize introspectMemory = _introspectMemory;
@synthesize catchZombies = _catchZombies;
@synthesize doNotIntrospectClasses = _doNotIntrospectClasses;
@synthesize stateFilePath = _stateFilePath;
@synthesize demangleLanguages = _demangleLanguages;
@synthesize reportsPath = _reportsPath;
@synthesize dataPath = _dataPath;


// ============================================================================
#pragma mark - Lifecycle -
// ============================================================================

IMPLEMENT_EXCLUSIVE_SHARED_INSTANCE(KSCrash)

- (id) init
{
    if((self = [super init]))
    {
        self.bundleName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
        if(self.bundleName == nil)
        {
            self.bundleName = @"Unknown";
        }

        NSArray* directories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                                   NSUserDomainMask,
                                                                   YES);
        if([directories count] == 0)
        {
            KSLOG_ERROR(@"Could not locate cache directory path.");
            goto failed;
        }
        NSString* cachePath = [directories objectAtIndex:0];
        if([cachePath length] == 0)
        {
            KSLOG_ERROR(@"Could not locate cache directory path.");
            goto failed;
        }
        NSString* storePathEnd = [@"KSCrash" stringByAppendingPathComponent:self.bundleName];
        NSString* basePath = [cachePath stringByAppendingPathComponent:storePathEnd];
        self.reportsPath = [basePath stringByAppendingPathComponent:@"Reports"];
        self.dataPath = [basePath stringByAppendingPathComponent:@"Data"];
        if(![self ensureDirectoryExists:self.reportsPath])
        {
            KSLOG_ERROR(@"Could not create reports path at %@", self.reportsPath);
            goto failed;
        }
        if(![self ensureDirectoryExists:self.dataPath])
        {
            KSLOG_ERROR(@"Could not create data path at %@", self.dataPath);
            goto failed;
        }

        NSString* stateFilename = [NSString stringWithFormat:@"%@" kCrashStateFilenameSuffix, self.bundleName];
        self.stateFilePath = [self.dataPath stringByAppendingPathComponent:stateFilename];

        self.nextCrashID = [NSUUID UUID].UUIDString;
        kscrs_initialize(self.bundleName.UTF8String, self.reportsPath.UTF8String);
        self.deleteBehaviorAfterSendAll = KSCDeleteAlways;
        self.searchThreadNames = NO;
        self.searchQueueNames = NO;
        self.introspectMemory = YES;
        self.catchZombies = NO;
    }
    return self;

failed:
    KSLOG_ERROR(@"Failed to initialize crash handler. Crash reporting disabled.");
    return nil;
}


// ============================================================================
#pragma mark - API -
// ============================================================================

- (void) setUserInfo:(NSDictionary*) userInfo
{
    NSError* error = nil;
    NSData* userInfoJSON = nil;
    if(userInfo != nil)
    {
        userInfoJSON = [self nullTerminated:[KSJSONCodec encode:userInfo
                                                        options:KSJSONEncodeOptionSorted
                                                          error:&error]];
        if(error != NULL)
        {
            KSLOG_ERROR(@"Could not serialize user info: %@", error);
            return;
        }
    }
    
    _userInfo = userInfo;
    kscrash_setUserInfoJSON([userInfoJSON bytes]);
}

- (void) setHandlingCrashTypes:(KSCrashType)handlingCrashTypes
{
    _handlingCrashTypes = kscrash_setHandlingCrashTypes(handlingCrashTypes);
}

- (void) setDeadlockWatchdogInterval:(double) deadlockWatchdogInterval
{
    _deadlockWatchdogInterval = deadlockWatchdogInterval;
    kscrash_setDeadlockWatchdogInterval(deadlockWatchdogInterval);
}

- (void) setPrintTraceToStdout:(bool)printTraceToStdout
{
    _printTraceToStdout = printTraceToStdout;
    kscrash_setPrintTraceToStdout(printTraceToStdout);
}

- (void) setOnCrash:(KSReportWriteCallback) onCrash
{
    _onCrash = onCrash;
    kscrash_setCrashNotifyCallback(onCrash);
}

- (void) setSearchThreadNames:(bool)searchThreadNames
{
    _searchThreadNames = searchThreadNames;
    kscrash_setSearchThreadNames(searchThreadNames);
}

- (void) setSearchQueueNames:(bool)searchQueueNames
{
    _searchQueueNames = searchQueueNames;
    kscrash_setSearchQueueNames(searchQueueNames);
}

- (void) setIntrospectMemory:(bool) introspectMemory
{
    _introspectMemory = introspectMemory;
    kscrash_setIntrospectMemory(introspectMemory);
}

- (void) setCatchZombies:(bool)catchZombies
{
    _catchZombies = catchZombies;
    kscrash_setCatchZombies(catchZombies);
}

- (void) setDoNotIntrospectClasses:(NSArray *)doNotIntrospectClasses
{
    _doNotIntrospectClasses = doNotIntrospectClasses;
    size_t count = [doNotIntrospectClasses count];
    if(count == 0)
    {
        kscrash_setDoNotIntrospectClasses(nil, 0);
    }
    else
    {
        NSMutableData* data = [NSMutableData dataWithLength:count * sizeof(const char*)];
        const char** classes = data.mutableBytes;
        for(size_t i = 0; i < count; i++)
        {
            classes[i] = [[doNotIntrospectClasses objectAtIndex:i] cStringUsingEncoding:NSUTF8StringEncoding];
        }
        kscrash_setDoNotIntrospectClasses(classes, count);
    }
}

- (BOOL) install
{
    char crashReportPath[KSCRS_MAX_PATH_LENGTH];
    kscrs_getCrashReportPath(crashReportPath);
    _handlingCrashTypes = kscrash_install(crashReportPath,
                                          self.stateFilePath.UTF8String,
                                          self.nextCrashID.UTF8String);
    if(self.handlingCrashTypes == 0)
    {
        return false;
    }

#if KSCRASH_HAS_UIAPPLICATION
    NSNotificationCenter* nCenter = [NSNotificationCenter defaultCenter];
    [nCenter addObserver:self
                selector:@selector(applicationDidBecomeActive)
                    name:UIApplicationDidBecomeActiveNotification
                  object:nil];
    [nCenter addObserver:self
                selector:@selector(applicationWillResignActive)
                    name:UIApplicationWillResignActiveNotification
                  object:nil];
    [nCenter addObserver:self
                selector:@selector(applicationDidEnterBackground)
                    name:UIApplicationDidEnterBackgroundNotification
                  object:nil];
    [nCenter addObserver:self
                selector:@selector(applicationWillEnterForeground)
                    name:UIApplicationWillEnterForegroundNotification
                  object:nil];
    [nCenter addObserver:self
                selector:@selector(applicationWillTerminate)
                    name:UIApplicationWillTerminateNotification
                  object:nil];
#endif
#if KSCRASH_HAS_NSEXTENSION
    NSNotificationCenter* nCenter = [NSNotificationCenter defaultCenter];
    [nCenter addObserver:self
                selector:@selector(applicationDidBecomeActive)
                    name:NSExtensionHostDidBecomeActiveNotification
                  object:nil];
    [nCenter addObserver:self
                selector:@selector(applicationWillResignActive)
                    name:NSExtensionHostWillResignActiveNotification
                  object:nil];
    [nCenter addObserver:self
                selector:@selector(applicationDidEnterBackground)
                    name:NSExtensionHostDidEnterBackgroundNotification
                  object:nil];
    [nCenter addObserver:self
                selector:@selector(applicationWillEnterForeground)
                    name:NSExtensionHostWillEnterForegroundNotification
                  object:nil];
#endif
    
    return true;
}

- (void) sendAllReportsWithCompletion:(KSCrashReportFilterCompletion) onCompletion
{
    NSArray* reports = [self allReports];
    
    KSLOG_INFO(@"Sending %d crash reports", [reports count]);
    
    [self sendReports:reports
         onCompletion:^(NSArray* filteredReports, BOOL completed, NSError* error)
     {
         KSLOG_DEBUG(@"Process finished with completion: %d", completed);
         if(error != nil)
         {
             KSLOG_ERROR(@"Failed to send reports: %@", error);
         }
         if((self.deleteBehaviorAfterSendAll == KSCDeleteOnSucess && completed) ||
            self.deleteBehaviorAfterSendAll == KSCDeleteAlways)
         {
             kscrs_deleteAllReports();
         }
         kscrash_i_callCompletion(onCompletion, filteredReports, completed, error);
     }];
}

- (void) deleteAllReports
{
    kscrs_deleteAllReports();
}

- (void) reportUserException:(NSString*) name
                      reason:(NSString*) reason
                    language:(NSString*) language
                  lineOfCode:(NSString*) lineOfCode
                  stackTrace:(NSArray*) stackTrace
            terminateProgram:(BOOL) terminateProgram
{
    const char* cName = [name cStringUsingEncoding:NSUTF8StringEncoding];
    const char* cReason = [reason cStringUsingEncoding:NSUTF8StringEncoding];
    const char* cLanguage = [language cStringUsingEncoding:NSUTF8StringEncoding];
    const char* cLineOfCode = [lineOfCode cStringUsingEncoding:NSUTF8StringEncoding];
    NSError* error = nil;
    NSData* jsonData = [KSJSONCodec encode:stackTrace options:0 error:&error];
    if(jsonData == nil || error != nil)
    {
        KSLOG_ERROR(@"Error encoding stack trace to JSON: %@", error);
        // Don't return, since we can still record other useful information.
    }
    NSString* jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    const char* cStackTrace = [jsonString cStringUsingEncoding:NSUTF8StringEncoding];

    kscrash_reportUserException(cName,
                                cReason,
                                cLanguage,
                                cLineOfCode,
                                cStackTrace,
                                terminateProgram);

    // If kscrash_reportUserException() returns, we did not terminate.
    // Set up IDs and paths for the next crash.

    self.nextCrashID = [NSUUID UUID].UUIDString;
    kscrsi_incrementCrashReportIndex();
    char crashReportPath[KSCRS_MAX_PATH_LENGTH];
    kscrs_getCrashReportPath(crashReportPath);
    kscrash_reinstall(crashReportPath,
                      self.stateFilePath.UTF8String,
                      self.nextCrashID.UTF8String);
}

// ============================================================================
#pragma mark - Advanced API -
// ============================================================================

#define SYNTHESIZE_CRASH_STATE_PROPERTY(TYPE, NAME) \
- (TYPE) NAME \
{ \
    return kscrashstate_currentState()->NAME; \
}

SYNTHESIZE_CRASH_STATE_PROPERTY(NSTimeInterval, activeDurationSinceLastCrash)
SYNTHESIZE_CRASH_STATE_PROPERTY(NSTimeInterval, backgroundDurationSinceLastCrash)
SYNTHESIZE_CRASH_STATE_PROPERTY(int, launchesSinceLastCrash)
SYNTHESIZE_CRASH_STATE_PROPERTY(int, sessionsSinceLastCrash)
SYNTHESIZE_CRASH_STATE_PROPERTY(NSTimeInterval, activeDurationSinceLaunch)
SYNTHESIZE_CRASH_STATE_PROPERTY(NSTimeInterval, backgroundDurationSinceLaunch)
SYNTHESIZE_CRASH_STATE_PROPERTY(int, sessionsSinceLaunch)
SYNTHESIZE_CRASH_STATE_PROPERTY(BOOL, crashedLastLaunch)

- (NSUInteger) reportCount
{
    return (NSUInteger)kscrs_getReportCount();
}

- (void) sendReports:(NSArray*) reports onCompletion:(KSCrashReportFilterCompletion) onCompletion
{
    if([reports count] == 0)
    {
        kscrash_i_callCompletion(onCompletion, reports, YES, nil);
        return;
    }
    
    if(self.sink == nil)
    {
        kscrash_i_callCompletion(onCompletion, reports, NO,
                                 [NSError errorWithDomain:[[self class] description]
                                                     code:0
                                              description:@"No sink set. Crash reports not sent."]);
        return;
    }
    
    [self.sink filterReports:reports
                onCompletion:^(NSArray* filteredReports, BOOL completed, NSError* error)
     {
         kscrash_i_callCompletion(onCompletion, filteredReports, completed, error);
     }];
}

- (NSString*) getReportType:(NSDictionary*) report
{
    NSDictionary* reportSection = report[@KSCrashField_Report];
    if(reportSection)
    {
        return reportSection[@KSCrashField_Type];
    }
    KSLOG_ERROR(@"Expected a report section in the report.");
    return nil;
}

- (void) convertTimestamp:(NSString*) key
                 inReport:(NSMutableDictionary*) report
{
    NSNumber* timestamp = [report objectForKey:key];
    if(timestamp == nil)
    {
        KSLOG_ERROR(@"entry '%@' not found", key);
        return;
    }
    if(![timestamp isKindOfClass:[NSNumber class]])
    {
        KSLOG_ERROR(@"'%@' should be a number, not %@", key, [key class]);
        return;
    }
    char timeString[21] = {0};
    rfc3339UtcStringFromUNIXTimestamp((time_t)[timestamp unsignedLongLongValue], timeString);
    [report setValue:[NSString stringWithUTF8String:timeString] forKey:key];
}

- (void) mergeDictWithKey:(NSString*) srcKey
          intoDictWithKey:(NSString*) dstKey
                 inReport:(NSMutableDictionary*) report
{
    NSDictionary* srcDict = [report objectForKey:srcKey];
    if(srcDict == nil)
    {
        // It's OK if the source dict didn't exist.
        return;
    }
    if(![srcDict isKindOfClass:[NSDictionary class]])
    {
        KSLOG_ERROR(@"'%@' should be a dictionary, not %@", srcKey, [srcDict class]);
        return;
    }
    
    NSDictionary* dstDict = [report objectForKey:dstKey];
    if(dstDict == nil)
    {
        dstDict = [NSDictionary dictionary];
    }
    if(![dstDict isKindOfClass:[NSDictionary class]])
    {
        KSLOG_ERROR(@"'%@' should be a dictionary, not %@", dstKey, [dstDict class]);
        return;
    }
    
    report[dstKey] = [srcDict mergedInto:dstDict];
    [report removeObjectForKey:srcKey];
}

- (void) performOnFields:(NSArray*) fieldPath inReport:(NSMutableDictionary*) report operation:(void (^)(id parent, id field)) operation okIfNotFound:(BOOL) isOkIfNotFound
{
    if(fieldPath.count == 0)
    {
        KSLOG_ERROR(@"Unexpected end of field path");
        return;
    }
    
    NSString* currentField = fieldPath[0];
    if(fieldPath.count > 1)
    {
        fieldPath = [fieldPath subarrayWithRange:NSMakeRange(1, fieldPath.count - 1)];
    }
    else
    {
        fieldPath = @[];
    }
    
    id field = report[currentField];
    if(field == nil)
    {
        if(!isOkIfNotFound)
        {
            KSLOG_ERROR(@"%@: No such field in report. Candidates are: %@", currentField, report.allKeys);
        }
        return;
    }
    
    if([field isKindOfClass:NSMutableDictionary.class])
    {
        [self performOnFields:fieldPath inReport:field operation:operation okIfNotFound:isOkIfNotFound];
    }
    else if([field isKindOfClass:[NSMutableArray class]])
    {
        for(id subfield in field)
        {
            if([subfield isKindOfClass:NSMutableDictionary.class])
            {
                [self performOnFields:fieldPath inReport:subfield operation:operation okIfNotFound:isOkIfNotFound];
            }
            else
            {
                operation(field, subfield);
            }
        }
    }
    else
    {
        operation(report, field);
    }
}

- (void) symbolicateField:(NSArray*) fieldPath inReport:(NSMutableDictionary*) report okIfNotFound:(BOOL) isOkIfNotFound
{
    NSString* lastPath = fieldPath[fieldPath.count - 1];
    [self performOnFields:fieldPath inReport:report operation:^(NSMutableDictionary* parent, NSString* field)
     {
         NSString* processedField = nil;
         if(self.demangleLanguages & KSCrashDemangleLanguageCPlusPlus)
         {
             processedField = [field demangledAsCPP];
         }
         if(processedField == nil && self.demangleLanguages & KSCrashDemangleLanguageSwift)
         {
             processedField = [field demangledAsSwift];
         }
         if(processedField == nil)
         {
             processedField = field;
         }
         parent[lastPath] = processedField;
     } okIfNotFound:isOkIfNotFound];
}

- (NSMutableDictionary*) fixupCrashReport:(NSDictionary*) report
{
    if(![report isKindOfClass:[NSDictionary class]])
    {
        KSLOG_ERROR(@"Report should be a dictionary, not %@", [report class]);
        return nil;
    }
    
    NSMutableDictionary* mutableReport = [report mutableCopy];
    NSMutableDictionary* mutableInfo = [report[@KSCrashField_Report] mutableCopy];
    if(mutableInfo != nil)
    {
        mutableReport[@KSCrashField_Report] = mutableInfo;
    }
    
    // Timestamp gets stored as a unix timestamp. Convert it to rfc3339.
    [self convertTimestamp:@KSCrashField_Timestamp inReport:mutableInfo];
    
    [self mergeDictWithKey:@KSCrashField_SystemAtCrash
           intoDictWithKey:@KSCrashField_System
                  inReport:mutableReport];
    
    [self mergeDictWithKey:@KSCrashField_UserAtCrash
           intoDictWithKey:@KSCrashField_User
                  inReport:mutableReport];
    
    NSMutableDictionary* crashReport = [report[@KSCrashField_Crash] mutableCopy];
    if(crashReport != nil)
    {
        mutableReport[@KSCrashField_Crash] = crashReport;
        crashReport[@KSCrashField_Diagnosis] = [[KSCrashDoctor doctor] diagnoseCrash:report];
    }
    
    [self symbolicateField:@[@"threads", @"backtrace", @"contents", @"symbol_name"] inReport:crashReport okIfNotFound:YES];
    [self symbolicateField:@[@"error", @"cpp_exception", @"name"] inReport:crashReport okIfNotFound:YES];
    
    return mutableReport;
}

- (NSDictionary*) reportWithID:(int64_t) reportID
{
    if(reportID <= 0)
    {
        KSLOG_ERROR(@"Report ID was %llx", reportID);
    }
    char* rawReport;
    int rawReportLength;
    kscrs_readReport(reportID, &rawReport, &rawReportLength);
    NSData* jsonData = [NSData dataWithBytesNoCopy:rawReport length:(NSUInteger)rawReportLength freeWhenDone:YES];

    NSError* error = nil;
    NSMutableDictionary* crashReport = [KSJSONCodec decode:jsonData
                                                   options:KSJSONDecodeOptionIgnoreNullInArray |
                                        KSJSONDecodeOptionIgnoreNullInObject |
                                        KSJSONDecodeOptionKeepPartialObject
                                                     error:&error];
    if(error != nil)
    {
        KSLOG_ERROR(@"Encountered error loading crash report %llx: %@", reportID, error);
    }
    if(crashReport == nil)
    {
        KSLOG_ERROR(@"Could not load crash report");
        return nil;
    }
    NSString* reportType = [self getReportType:crashReport];
    if([reportType isEqualToString:@KSCrashReportType_Standard] || [reportType isEqualToString:@KSCrashReportType_Minimal])
    {
        crashReport = [self fixupCrashReport:crashReport];
    }

    NSMutableDictionary* recrashReport = crashReport[@KSCrashField_RecrashReport];
    if(recrashReport != nil)
    {
        crashReport[@KSCrashField_RecrashReport] = [self fixupCrashReport:recrashReport];
    }
    
    return crashReport;
}

- (NSArray*) allReports
{
    int reportCount = kscrs_getReportCount();
    int64_t reportIDs[reportCount];
    reportCount = kscrs_getReportIDs(reportIDs, reportCount);
    NSMutableArray* reports = [NSMutableArray arrayWithCapacity:(NSUInteger)reportCount];
    for(int i = 0; i < reportCount; i++)
    {
        NSDictionary* report = [self reportWithID:reportIDs[i]];
        if(report != nil)
        {
            [reports addObject:report];
        }
    }
    
    return reports;
}

- (BOOL) redirectConsoleLogsToFile:(NSString*) fullPath overwrite:(BOOL) overwrite
{
    if(kslog_setLogFilename([fullPath UTF8String], overwrite))
    {
        self.logFilePath = fullPath;
        return YES;
    }
    return NO;
}

- (BOOL) redirectConsoleLogsToDefaultFile
{
    NSString* logFilename = [NSString stringWithFormat:@"%@" kCrashLogFilenameSuffix, self.bundleName];
    NSString* logFilePath = [self.dataPath stringByAppendingPathComponent:logFilename];
    if(![self redirectConsoleLogsToFile:logFilePath overwrite:YES])
    {
        KSLOG_ERROR(@"Could not redirect logs to %@", logFilePath);
        return NO;
    }
    return YES;
}


// ============================================================================
#pragma mark - Utility -
// ============================================================================

- (BOOL) ensureDirectoryExists:(NSString*) path
{
    NSError* error = nil;
    NSFileManager* fm = [NSFileManager defaultManager];
    
    if(![fm fileExistsAtPath:path])
    {
        if(![fm createDirectoryAtPath:path
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&error])
        {
            KSLOG_ERROR(@"Could not create directory %@: %@.", path, error);
            return NO;
        }
    }
    
    return YES;
}

- (NSMutableData*) nullTerminated:(NSData*) data
{
    if(data == nil)
    {
        return NULL;
    }
    NSMutableData* mutable = [NSMutableData dataWithData:data];
    [mutable appendBytes:"\0" length:1];
    return mutable;
}


// ============================================================================
#pragma mark - Callbacks -
// ============================================================================

- (void) applicationDidBecomeActive
{
    kscrashstate_notifyAppActive(true);
}

- (void) applicationWillResignActive
{
    kscrashstate_notifyAppActive(false);
}

- (void) applicationDidEnterBackground
{
    kscrashstate_notifyAppInForeground(false);
}

- (void) applicationWillEnterForeground
{
    kscrashstate_notifyAppInForeground(true);
}

- (void) applicationWillTerminate
{
    kscrashstate_notifyAppTerminate();
}

@end


//! Project version number for KSCrashFramework.
const double KSCrashFrameworkVersionNumber = 1.101;

//! Project version string for KSCrashFramework.
const unsigned char KSCrashFrameworkVersionString[] = "1.10.1";
