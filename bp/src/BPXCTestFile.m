//  Copyright 2016 LinkedIn Corporation
//  Licensed under the BSD 2-Clause License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at https://opensource.org/licenses/BSD-2-Clause
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and limitations under the License.

#import "BPXCTestFile.h"
#import "BPConstants.h"
#import "BPTestClass.h"
#import "BPUtils.h"
#import "SimulatorHelper.h"

@implementation BPXCTestFile

NSString *swiftNmCmdline = @"nm -gU '%@' | cut -d' ' -f3 | xargs -s 131072 xcrun swift-demangle | cut -d' ' -f3 | grep -e '[\\.|_]'test";
NSString *objcNmCmdline = @"nm -U '%@' | grep ' t ' | cut -d' ' -f3,4 | cut -d'-' -f2 | cut -d'[' -f2 | cut -d']' -f1 | grep ' test'";

+ (instancetype)BPXCTestFileFromXCTestBundle:(NSString *)testBundlePath
                            andHostAppBundle:(NSString *)testHostPath
                                   withError:(NSError *__autoreleasing *)errPtr {
    return [BPXCTestFile BPXCTestFileFromXCTestBundle:testBundlePath
                                     andHostAppBundle:testHostPath
                                   andUITargetAppPath:nil
                                            withError:errPtr];
}

+ (instancetype)BPXCTestFileFromXCTestBundle:(NSString *)path
                            andHostAppBundle:(NSString *)testHostPath
                          andUITargetAppPath:(NSString *)UITargetAppPath
                                   withError:(NSError **)errPtr {
    BOOL isDir = NO;

    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        BP_SET_ERROR(errPtr, @"Could not find test bundle at path %@.", path);
        return nil;
    }
    NSString *baseName = [[path lastPathComponent] stringByDeletingPathExtension];
    path = [path stringByAppendingPathComponent:baseName];
    BPXCTestFile *xcTestFile = [[BPXCTestFile alloc] init];
    xcTestFile.name = [path lastPathComponent];
    xcTestFile.testHostPath = testHostPath;
    xcTestFile.UITargetAppPath = UITargetAppPath;
    xcTestFile.testBundlePath = [path stringByDeletingLastPathComponent];

    NSString *cmd = [NSString stringWithFormat:swiftNmCmdline, path];
    NSString *output = [BPUtils runShell:cmd];
    NSArray<NSString *>* testsArray = [output componentsSeparatedByString:@"\n"];
    NSMutableDictionary *testClassesDict = [[NSMutableDictionary alloc] init];
    NSMutableArray *allClasses = [[NSMutableArray alloc] init];

    for (NSString *testName in testsArray) {
        NSArray *parts = [testName componentsSeparatedByString:@"."];
        if (parts.count != 3) {
            continue;
        }
        BPTestClass *testClass = testClassesDict[parts[1]];
        if (!testClass) {
            testClass = [[BPTestClass alloc] initWithName:parts[1]];
            testClassesDict[parts[1]] = testClass;
            [allClasses addObject:testClass];
        }
        if (![parts[2] containsString:@"DISABLE"]) {
            NSString *trimmedTestName = [BPUtils trimTrailingParanthesesFromTestName:parts[2]];
            if (trimmedTestName == nil) {
                continue;
            }
            [testClass addTestCase:[[BPTestCase alloc] initWithName:trimmedTestName]];
        }
    }

    cmd = [NSString stringWithFormat:objcNmCmdline, path];
    output = [BPUtils runShell:cmd];
    testsArray = [output componentsSeparatedByString:@"\n"];
    for (NSString *line in testsArray) {
        NSArray *parts = [line componentsSeparatedByString:@" "];
        if (parts.count != 2) {
            continue;
        }
        BPTestClass *testClass = testClassesDict[parts[0]];
        if (!testClass) {
            testClass = [[BPTestClass alloc] initWithName:parts[0]];
            testClassesDict[parts[0]] = testClass;
            [allClasses addObject:testClass];
        }
        [testClass addTestCase:[[BPTestCase alloc] initWithName:parts[1]]];
    }

    xcTestFile.testClasses = [NSArray arrayWithArray:allClasses];
    return xcTestFile;
}

+ (instancetype)BPXCTestFileFromDictionary:(NSDictionary *)dict
                              withTestRoot:(NSString *)testRoot
                              andXcodePath:(NSString *)xcodePath
                                  andError:(NSError *__autoreleasing *)errPtr {
    NSAssert(dict, @"A dictionary should be provided");
    NSAssert(testRoot, @"A testRoot argument must be supplied");
    NSString * const TESTROOT = @"__TESTROOT__";
    NSString * const TESTHOST = @"__TESTHOST__";
    NSString * const PLATFORMS = @"__PLATFORMS__";
    NSString *testHostPath = [dict objectForKey:@"TestHostPath"];
    if (!testHostPath) {
        BP_SET_ERROR(errPtr, @"No 'TestHostPath' found");
        return nil;
    }
    testHostPath = [testHostPath stringByReplacingOccurrencesOfString:TESTROOT withString:testRoot];
    NSString *testBundlePath = [dict objectForKey:@"TestBundlePath"];
    if (!testBundlePath) {
        BP_SET_ERROR(errPtr, @"No 'TestBundlePath' found");
        return nil;
    }
    /*testBundlePath is expected to be "__TESTHOST__/PlugIns/.." or "__TESTROOT__/Debug-iphonesimulator/BPSampleApp.app/PlugIns/BPSampleAppHangingTests.xctest" or contains "__PLATFORMS__"
     The following code is to expand these into a full path
     */
    if ([testBundlePath rangeOfString:TESTHOST].location != NSNotFound) {
        testBundlePath = [testBundlePath stringByReplacingOccurrencesOfString:TESTHOST withString:testHostPath];
    } else if ([testBundlePath rangeOfString:TESTROOT].location != NSNotFound) {
        testBundlePath = [testBundlePath stringByReplacingOccurrencesOfString:TESTROOT withString:testRoot];
    } else if ([testHostPath rangeOfString:PLATFORMS].location != NSNotFound) {
        NSString *platformsPath = [xcodePath stringByAppendingPathComponent:@"Platforms"];
        testBundlePath = [testBundlePath stringByReplacingOccurrencesOfString:PLATFORMS withString:platformsPath];
    } else {
        [BPUtils printInfo:ERROR withString:@"testBundlePath is incorrect, please check xctestrun file"];
    }
    NSString * UITargetAppPath = [dict objectForKey:@"UITargetAppPath"];
    if (UITargetAppPath) {
        UITargetAppPath = [UITargetAppPath stringByReplacingOccurrencesOfString:TESTROOT withString:testRoot];
    }
    BPXCTestFile *xcTestFile = [BPXCTestFile BPXCTestFileFromXCTestBundle:testBundlePath
                                                         andHostAppBundle:testHostPath
                                                       andUITargetAppPath:UITargetAppPath
                                                                withError:errPtr];
    if (!xcTestFile) {
        return nil;
    }
    xcTestFile.testHostPath = testHostPath;
    xcTestFile.testBundlePath = testBundlePath;
    xcTestFile.testHostBundleIdentifier = [dict objectForKey:@"TestHostBundleIdentifier"];
    NSArray<NSString *> *commandLineArguments = [dict objectForKey:@"CommandLineArguments"];
    if (commandLineArguments) {
        xcTestFile.commandLineArguments = [[NSArray alloc] initWithArray:commandLineArguments];
    }
    NSMutableDictionary<NSString *, NSString *> *environment = [dict objectForKey:@"EnvironmentVariables"];
    if (environment) {
        [environment removeObjectForKey:@"DYLD_LIBRARY_PATH"];
        xcTestFile.environmentVariables = [[NSDictionary alloc] initWithDictionary:environment];
    }
    NSArray<NSString *> *skipTestIdentifiers = [dict objectForKey:@"SkipTestIdentifiers"];
    if (skipTestIdentifiers) {
        xcTestFile.skipTestIdentifiers = [[NSArray alloc] initWithArray:skipTestIdentifiers];
    }
    NSArray<NSString *> *dependencies = [dict objectForKey:@"DependentProductPaths"];
    if (dependencies) {
        NSMutableDictionary <NSString *, NSString *> *dependenciesWithBundleIDs = [NSMutableDictionary dictionary];
        for (NSString *dependency in dependencies) {
            NSString *expandedDependency = [dependency stringByReplacingOccurrencesOfString:TESTROOT withString:testRoot];
            NSString *bundleID = [SimulatorHelper bundleIdForPath:expandedDependency];
            dependenciesWithBundleIDs[bundleID] = expandedDependency;
        }
        xcTestFile.dependencies = dependenciesWithBundleIDs;
    }
    return xcTestFile;
}

+ (instancetype)BPXCTestFileFromBPTestPlan:(BPTestPlan*)testPlan
                                  withName:(NSString*)name
                                  andError:(NSError **)errPtr {
    
    BPXCTestFile *xcTestFile = [BPXCTestFile
                                BPXCTestFileFromXCTestBundle:testPlan.testBundlePath
                                andHostAppBundle:testPlan.testHost
                                andUITargetAppPath:testPlan.uiTargetAppPath
                                withError:errPtr];
    xcTestFile.name = name;
    xcTestFile.environmentVariables = testPlan.environment;
    xcTestFile.dependencies = testPlan.dependencies;
    
    NSMutableArray<NSString *> *args = [[NSMutableArray alloc] initWithCapacity:testPlan.arguments.count * 2];
    for (NSString *key in xcTestFile.commandLineArguments) {
        [args addObject:key];
        [args addObject:[testPlan.arguments objectForKey:key]];
    }
    xcTestFile.commandLineArguments = args;
    
    return xcTestFile;
}

- (void)listTestClasses {
    for (BPTestClass *testClass in self.testClasses) {
        [testClass listTestCases];
    }
}

- (NSUInteger)numTests {
    int count = 0;
    for (BPTestClass *testClass in self.testClasses) {
        count += [testClass numTests];
    }
    return count;
}

- (NSArray *)allTestCases {
    NSMutableArray *ret = [[NSMutableArray alloc] init];
    for (BPTestClass *testClass in self.testClasses) {
        for (BPTestCase *testCase in testClass.testCases) {
            [ret addObject:[NSString stringWithFormat:@"%@/%@", testClass.name, testCase.name]];
        }
    }
    return ret;
}

- (NSString *)description {
    int tests = 0;
    for (BPTestClass *c in self.testClasses) {
        tests += c.numTests;
    }
    return [NSString stringWithFormat:@"%@ / %lu classes / %d tests", self.name, [self.testClasses count], tests];
}

- (NSString *)debugDescription {
    NSArray *allTestClasses = self.allTestCases;
    return [NSString stringWithFormat:@"<%@: %p> allTests: %lu skipped: %lu", [self class], self, (unsigned long)allTestClasses.count, (unsigned long)self.skipTestIdentifiers.count];
}

- (id)copyWithZone:(NSZone *)zone {
    BPXCTestFile *copy = [[BPXCTestFile alloc] init];
    if (copy) {
        copy.name = self.name;
        copy.testClasses = self.testClasses;
        copy.commandLineArguments = self.commandLineArguments;
        copy.environmentVariables = self.environmentVariables;
        copy.dependencies = self.dependencies;
        copy.testHostPath = self.testHostPath;
        copy.testHostBundleIdentifier = self.testHostBundleIdentifier;
        copy.testBundlePath= self.testBundlePath;
        copy.UITargetAppPath = self.UITargetAppPath;
        copy.skipTestIdentifiers = self.skipTestIdentifiers;
    }
    return copy;
}

- (BOOL)isEqual:(id)object{
    return [object isKindOfClass:[BPXCTestFile class]] && [self.name isEqualToString: ((BPXCTestFile*)object).name];
}
@end
