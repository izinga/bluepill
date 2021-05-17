//
//     Generated by class-dump 3.5 (64 bit) (Debug version compiled May 11 2021 09:30:43).
//
//  Copyright (C) 1997-2019 Steve Nygard.
//

#import <objc/NSObject.h>

@class NSMutableArray, XCTestCase;

__attribute__((visibility("hidden")))
@interface XCTAttachmentManager : NSObject
{
    _Bool _isValid;
    XCTestCase *_testCase;
    NSMutableArray *_attachments;
}

+ (void)_synthesizeActivityForAttachment:(id)arg1 testCase:(id)arg2;
- (void).cxx_destruct;
@property _Bool isValid; // @synthesize isValid=_isValid;
@property(readonly) NSMutableArray *attachments; // @synthesize attachments=_attachments;
@property(readonly) XCTestCase *testCase; // @synthesize testCase=_testCase;
- (void)enqueueAttachment:(id)arg1;
- (void)dequeueAndReportBackgroundAttachments;
- (void)ensureNoRemainingAttachments;
- (void)_invalidate;
- (void)dealloc;
- (id)initWithTestCase:(id)arg1;

@end

