//
//     Generated by class-dump 3.5 (64 bit) (Debug version compiled May 11 2021 09:30:43).
//
//  Copyright (C) 1997-2019 Steve Nygard.
//

#import <objc/NSObject.h>

#import <XCTest/NSCopying-Protocol.h>
#import <XCTest/NSMutableCopying-Protocol.h>
#import <XCTest/NSSecureCoding-Protocol.h>

@class NSArray, NSDate, NSError, NSString, XCTSourceCodeContext;

@interface XCTIssue : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>
{
    struct atomic_flag _failureBreakPointCalled;
    _Bool _isExpectedFailure;
    _Bool _didInterruptTest;
    _Bool _shouldInterruptTest;
    long long _type;
    NSString *_compactDescription;
    NSString *_detailedDescription;
    XCTSourceCodeContext *_sourceCodeContext;
    NSError *_associatedError;
    NSArray *_attachments;
    NSDate *_timestamp;
    unsigned long long _threadId;
    NSString *_expectedFailureReason;
}

+ (_Bool)supportsSecureCoding;
+ (id)issueWithType:(long long)arg1 compactDescription:(id)arg2 callStackAddresses:(id)arg3 filePath:(id)arg4 lineNumber:(long long)arg5;
+ (id)issueWithException:(id)arg1;
+ (id)issueWithType:(long long)arg1 compactDescription:(id)arg2 associatedError:(id)arg3;
- (void).cxx_destruct;
@property _Bool shouldInterruptTest; // @synthesize shouldInterruptTest=_shouldInterruptTest;
@property _Bool didInterruptTest; // @synthesize didInterruptTest=_didInterruptTest;
@property _Bool isExpectedFailure; // @synthesize isExpectedFailure=_isExpectedFailure;
@property(copy) NSString *expectedFailureReason; // @synthesize expectedFailureReason=_expectedFailureReason;
@property unsigned long long threadId; // @synthesize threadId=_threadId;
@property struct atomic_flag failureBreakPointCalled; // @synthesize failureBreakPointCalled=_failureBreakPointCalled;
@property(copy) NSDate *timestamp; // @synthesize timestamp=_timestamp;
@property(copy) NSArray *attachments; // @synthesize attachments=_attachments;
@property(retain) NSError *associatedError; // @synthesize associatedError=_associatedError;
@property(retain) XCTSourceCodeContext *sourceCodeContext; // @synthesize sourceCodeContext=_sourceCodeContext;
@property(copy) NSString *detailedDescription; // @synthesize detailedDescription=_detailedDescription;
@property(copy) NSString *compactDescription; // @synthesize compactDescription=_compactDescription;
@property long long type; // @synthesize type=_type;
- (_Bool)matchesLegacyPropertiesOfIssue:(id)arg1;
- (_Bool)isEqual:(id)arg1;
- (unsigned long long)hash;
- (id)initWithCoder:(id)arg1;
- (void)encodeWithCoder:(id)arg1;
@property(readonly) _Bool isLegacyExpectedFailure;
@property(readonly) _Bool isFailure;
- (id)description;
- (void)_updateAttachmentsTimestamps;
- (id)mutableCopyWithZone:(struct _NSZone *)arg1;
- (id)copyWithZone:(struct _NSZone *)arg1;
- (id)initWithType:(long long)arg1 compactDescription:(id)arg2 detailedDescription:(id)arg3 sourceCodeContext:(id)arg4 associatedError:(id)arg5 attachments:(id)arg6;
- (id)initWithType:(long long)arg1 compactDescription:(id)arg2;

@end

